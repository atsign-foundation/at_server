import 'dart:collection';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_access.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart' as handler_util;
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';

final String paramFullCommandAsReceived = 'FullCommandAsReceived';

abstract class AbstractVerbHandler implements VerbHandler {
  final AtKeyValueStore<String, AtData, AtMetaData?> keyStore;

  late AtSignLogger logger;
  ResponseHandlerManager responseManager =
      DefaultResponseHandlerManager.getInstance();

  RegExp perEnrollmentRegex =
      RegExp(EnrollmentConstants.regexForPerEnrollmentNamespaces);

  AbstractVerbHandler(this.keyStore) {
    logger = AtSignLogger(runtimeType.toString());
  }

  final rand = Random.secure();

  /// Parses a given command against a corresponding verb syntax.
  HashMap<String, String?> parse(String command) {
    try {
      return handler_util.getVerbParam(getVerb().syntax(), command);
    } on InvalidSyntaxException {
      throw InvalidSyntaxException('Invalid syntax. ${getVerb().usage()}');
    }
  }

  @override
  Future<void> process(String command, InboundConnection atConnection) async {
    var response = await processInternal(command, atConnection);
    var responseHandler = responseManager.getResponseHandler(getVerb());
    await responseHandler.process(atConnection, response);
  }

  Future<Response> processInternal(
      String command, InboundConnection atConnection) async {
    var response = Response();
    var atConnectionMetadata = atConnection.metaData;
    if (getVerb().requiresAuth() && !atConnectionMetadata.isAuthenticated) {
      throw UnAuthenticatedException('Command cannot be executed without auth');
    }
    (bool, Response) isEnrollmentActive =
        await _verifyIfEnrollmentIsActive(response, atConnectionMetadata);
    if (isEnrollmentActive.$1 == false) {
      await atConnection.close();
      return isEnrollmentActive.$2;
    }
    try {
      var verbParams = parse(command);
      // TODO This is not ideal. Would be better to make it so that processVerb takes command as an argument also.
      verbParams[paramFullCommandAsReceived] = command;
      await processVerb(response, verbParams, atConnection);
      if (this is SyncProgressiveVerbHandler) {
        final verbHandler = this as SyncProgressiveVerbHandler;
        verbHandler.logResponse(response.data!);
      } else {
        logger.finer(
            'Verb : ${getVerb().name()}  Response: ${response.toString()}');
      }
      return response;
    } on Exception {
      rethrow;
    }
  }

  /// The wire error code a connection is closed with when its enrollment is
  /// no longer [EnrollmentStatus.approved].
  static String _closeCodeForState(String? state) {
    if (state == EnrollmentStatus.denied.name) return 'AT0025';
    if (state == EnrollmentStatus.pending.name) return 'AT0026';
    if (state == EnrollmentStatus.revoked.name) return 'AT0027';
    return 'AT0028';
  }

  /// Whether the connection's enrollment, if it has one, is still approved.
  Future<(bool, Response)> _verifyIfEnrollmentIsActive(
      Response response, AtConnectionMetaData atConnectionMetadata) async {
    if ((atConnectionMetadata as InboundConnectionMetadata).enrollmentId ==
        null) {
      if (logger.isLoggable('finest')) {
        logger.finest(
            "Enrollment id is not found. Returning true from _verifyIfEnrollmentIsActive");
      }
      return (true, response);
    }
    try {
      EnrollDataStoreValue enrollDataStoreValue =
          await AtSecondaryServerImpl.getInstance()
              .enrollmentManager
              .getEnrollmentById(atConnectionMetadata.enrollmentId!);
      final String? state = enrollDataStoreValue.approval?.state;
      if (state != EnrollmentStatus.approved.name) {
        final String describedState = state ?? 'in an unreadable state';
        logger.severe(
            'The enrollment id: ${atConnectionMetadata.enrollmentId} is $describedState. Closing the connection');
        response
          ..isError = true
          ..errorCode = _closeCodeForState(state)
          ..errorMessage =
              'The enrollment id: ${(atConnectionMetadata).enrollmentId} is $describedState. Closing the connection';
        return (false, response);
      }
      // NOTE an expired enrollment is removed from the keystore, so it
      // surfaces here as KeyNotFoundException.
    } on KeyNotFoundException {
      logger.severe(
          'The enrollment id: ${atConnectionMetadata.enrollmentId} is expired. Closing the connection');
      response
        ..isError = true
        ..errorCode = 'AT0028'
        ..errorMessage =
            'The enrollment id: ${(atConnectionMetadata).enrollmentId} is expired. Closing the connection';
      return (false, response);
    }
    if (logger.isLoggable('finest')) {
      logger.finest(
          "Enrollment id ${atConnectionMetadata.enrollmentId} is active. Returning true from _verifyIfEnrollmentIsActive");
    }
    return (true, response);
  }

  /// The [Verb] this handler serves.
  Verb getVerb();

  /// Processes [verbParams], the groups parsed out of the command, on behalf
  /// of [atConnection], and sets the result in [response].
  Future<void> processVerb(Response response,
      HashMap<String, String?> verbParams, InboundConnection atConnection);

  static String enrollmentReservedNamespace(String enrollmentId) {
    return '$enrollmentId.${EnrollmentConstants.perEnrollmentApproved}';
  }

  /// Matches a per-enrollment reserved-namespace key (`<EnId>.a|r|d.__e@…`),
  /// capturing the owning enrollment id in the `EnId` group.
  static final RegExp _perEnrollmentReservedKeyRegex =
      RegExp(EnrollmentConstants.regexForPerEnrollmentNamespaces);

  /// Whether [atKey] lives in a per-enrollment reserved namespace
  /// (`<id>.a|r|d.__e`) owned by an enrollment other than [enrollmentId].
  ///
  /// A `public:` key is exempt for reads only, which is what [isMutating]
  /// distinguishes.
  static bool isForeignPerEnrollmentReservedKey(
      String atKey, String? enrollmentId,
      {bool isMutating = false}) {
    // NOTE folded with the keystore's own fold, so the tests below are about
    // the string the store holds rather than the caller's spelling of it.
    final String key = canonicalAtKey(atKey);
    if (!isMutating && key.startsWith('public:')) {
      return false;
    }
    final match = _perEnrollmentReservedKeyRegex.firstMatch(key);
    if (match == null) {
      return false;
    }
    // NOTE the owning id comes out of a caller-supplied atKey, so it is
    // folded to the keystore's own form before comparison.
    return EnrollmentManager.canonicalEnrollmentId(
            match.namedGroup('EnId')!) !=
        enrollmentId;
  }

  /// Whether [atKey]'s namespace is the enrollment-manage namespace
  /// (`__manage`), i.e. an enrollment record or its encrypted key material
  /// (PEK/SEK).
  static bool isEnrollManageKey(String atKey) {
    return canonicalAtKey(atKey)
        .contains('.${EnrollmentConstants.enrollManageNamespace}@');
  }

  /// Whether this connection may retrieve, modify or delete data in a
  /// namespace: "r" or "rw" for a lookup or local lookup, "rw" for an update
  /// or delete.
  ///
  /// Uses [namespace] when passed, otherwise the namespace of [atKey].
  Future<bool> isAuthorized(InboundConnectionMetadata inboundConnectionMetadata,
      {String? atKey,
      String? namespace,
      String enrolledNamespaceAccess = '',
      String operation = ''}) async {
    final enrollmentId = inboundConnectionMetadata.enrollmentId;
    // NOTE ahead of the short circuits below, which return early for a CRAM
    // connection and for one carrying no enrollment id.
    refuseFlatCredentialWrite(inboundConnectionMetadata, atKey);
    if (isCramConnection(inboundConnectionMetadata)) {
      return true;
    }
    if (enrollmentId == null) {
      return false;
    }
    final enroll = await resolveEnrollment(enrollmentId);
    return isAuthorizedSync(enroll, enrollmentId,
        cram: false,
        atKey: atKey,
        namespace: namespace,
        enrolledNamespaceAccess: enrolledNamespaceAccess,
        operation: operation);
  }

  /// Whether [md] is a CRAM-authenticated connection, the one kind that
  /// holds the atSign itself rather than an enrollment.
  static bool isCramConnection(InboundConnectionMetadata md) =>
      md.isAuthenticated && md.authType == AuthType.cram;

  /// Refuses a write of `privatekey:at_pkam_publickey` by any connection
  /// except a CRAM connection sending `update`, plain or json; `update:meta`
  /// is refused. Throws [UnAuthorizedException]. Returns for any other key or
  /// non-writing verb.
  void refuseFlatCredentialWrite(
      InboundConnectionMetadata md, String? atKey) {
    if (atKey == null || !isWritingVerb()) return;
    if (canonicalAtKey(atKey) != AtConstants.atPkamPublicKey) return;
    if (isCramConnection(md) && getVerb() is Update) {
      logger.info('Admitting a write of ${AtConstants.atPkamPublicKey} '
          'over a CRAM connection; the value is installed as the '
          '${EnrollmentManager.primaryEnrollmentId} enrollment rather than '
          'as a flat key');
      return;
    }
    throw UnAuthorizedException(flatCredentialWriteRefusal);
  }

  /// What [refuseFlatCredentialWrite] says.
  static const String flatCredentialWriteRefusal =
      '${AtConstants.atPkamPublicKey} may not be written. It is the '
      'credential legacy PKAM authenticates against, it carries no '
      'enrollment id, and nothing can revoke it once it is installed. '
      'Enrol a credential with enroll:request and rotate it with '
      'enroll:update, both of which leave a record that can be withdrawn';

  /// The enrollment record for [enrollmentId], or `null` when it cannot be
  /// found; callers treat `null` as "deny all".
  Future<EnrollDataStoreValue?> resolveEnrollment(String enrollmentId) async {
    try {
      return await AtSecondaryServerImpl.getInstance()
          .enrollmentManager
          .getEnrollmentById(enrollmentId);
    } on KeyNotFoundException {
      logger.severe('Could not retrieve enrollment data for $enrollmentId');
      return null;
    }
  }

  /// Synchronous per-entry authorisation against an enrollment already
  /// fetched by [resolveEnrollment].
  bool isAuthorizedSync(
      EnrollDataStoreValue? enrollDataStoreValue, String? enrollmentId,
      {required bool cram,
      String? atKey,
      String? namespace,
      String enrolledNamespaceAccess = '',
      String operation = ''}) {
    if (cram) {
      return true;
    }
    if (enrollmentId == null || enrollDataStoreValue == null) {
      return false;
    }

    bool isValidEnrollment = _applyEnrollmentValidations(
        enrollDataStoreValue, operation, atKey, namespace);
    if (!isValidEnrollment) {
      return isValidEnrollment;
    }

    // NOTE denied ahead of the wildcard fallback below, which a holder of
    // '*:rw' would otherwise reach another enrollment's reserved keys through.
    if (atKey != null &&
        isForeignPerEnrollmentReservedKey(atKey, enrollmentId,
            isMutating: isMutatingVerb())) {
      return false;
    }

    // NOTE a null verdict defers to the namespace check below.
    final bool? rootKeyVerdict = _decideRootKey(atKey, enrollDataStoreValue);
    if (rootKeyVerdict != null) {
      return rootKeyVerdict;
    }

    // NOTE AtKey.fromString raises Errors as well as Exceptions on some key
    // shapes held in the keystore and the commit log.
    String keyWithNamespace = '';
    if ((namespace == null || namespace.isEmpty) && atKey != null) {
      try {
        AtKey atKeyObj = AtKey.fromString(atKey);
        namespace = atKeyObj.namespace;
        if (namespace != null && namespace.isNotEmpty) {
          keyWithNamespace = '${atKeyObj.key}.$namespace';
        }
      } catch (_) {
        namespace = null;
      }
    }

    // NOTE every enrollment reads the __atserver namespace and none writes it.
    if (!enrollDataStoreValue.namespaces
        .containsKey(AtConstants.atServerReservedNamespace)) {
      enrollDataStoreValue.namespaces[AtConstants.atServerReservedNamespace] =
          'r';
    }

    // NOTE every enrollment has rw on the namespace unique to itself.
    enrollDataStoreValue.namespaces[enrollmentReservedNamespace(enrollmentId)] =
        'rw';

    (String, String?) authorizedNamespace = _checkForNamespaceAuthorization(
        enrollDataStoreValue, namespace, keyWithNamespace);

    if (authorizedNamespace.$1.isEmpty ||
        (authorizedNamespace.$2 == null || authorizedNamespace.$2!.isEmpty)) {
      return false;
    }

    // NOTE __manage is reachable only by an enrollment holding it explicitly,
    // and then only via otp/enroll/monitor, never through the '*' fallback.
    if (namespace == EnrollmentConstants.enrollManageNamespace ||
        authorizedNamespace.$1 == EnrollmentConstants.enrollManageNamespace) {
      final bool holdsManageNamespaceExplicitly =
          authorizedNamespace.$1 == EnrollmentConstants.enrollManageNamespace;
      final String? callerAccess = authorizedNamespace.$2;
      // NOTE [enrolledNamespaceAccess] is the access the TARGET enrollment
      // holds, and is empty where the caller reaches a __manage key rather
      // than another enrollment's grants.
      final bool targetHoldsWriteOnManage =
          EnrollmentAccess.allowsWrite(enrolledNamespaceAccess);
      // ignore: experimental_member_use
      return holdsManageNamespaceExplicitly &&
          (getVerb() is Otp || getVerb() is Enroll || getVerb() is Monitor) &&
          (EnrollmentAccess.allowsWrite(callerAccess) ||
              (EnrollmentAccess.allowsRead(callerAccess) &&
                  !targetHoldsWriteOnManage));
    }
    return checkEnrollmentNamespaceAccess(authorizedNamespace.$2!,
        enrolledNamespaceAccess: enrolledNamespaceAccess);
  }

  /// The enrolled namespace covering [namespace], and the access held on it.
  ///
  /// Returns an empty string and `null` when nothing matches.
  (String, String?) _checkForNamespaceAuthorization(
      EnrollDataStoreValue enrollDataStoreValue,
      String? namespace,
      String? keyWithNamespace) {
    String authorisedNamespace = '';
    String? access;
    if (namespace != null && namespace.isNotEmpty) {
      for (String enrolledNamespace in enrollDataStoreValue.namespaces.keys) {
        if ('.$namespace'.endsWith('.$enrolledNamespace')) {
          authorisedNamespace = enrolledNamespace;
          break;
        }
      }
    }

    // NOTE AtKey.namespace returns only the last segment of a dotted
    // namespace, so a multi-segment enrolled namespace needs the whole key.
    if (keyWithNamespace != null &&
        keyWithNamespace.isNotEmpty &&
        authorisedNamespace.isEmpty) {
      for (String enrolledNamespace in enrollDataStoreValue.namespaces.keys) {
        if (keyWithNamespace.endsWith('.$enrolledNamespace')) {
          authorisedNamespace = enrolledNamespace;
          break;
        }
      }
    }
    if (authorisedNamespace.isEmpty &&
        enrollDataStoreValue.namespaces
            .containsKey(EnrollmentConstants.allNamespaces)) {
      authorisedNamespace = EnrollmentConstants.allNamespaces;
    }
    access = enrollDataStoreValue.namespaces[authorisedNamespace];
    return (authorisedNamespace, access);
  }

  bool _applyEnrollmentValidations(EnrollDataStoreValue enrollDataStoreValue,
      String operation, String? atKey, String? namespace) {
    if (enrollDataStoreValue.approval?.state !=
        EnrollmentStatus.approved.name) {
      return false;
    }
    if (operation.isNotEmpty &&
        enrollDataStoreValue.namespaces
                .containsKey(EnrollmentConstants.enrollManageNamespace) ==
            false) {
      logger.warning('Failed to $operation the request.'
          ' The enrollment does not have access to "__manage" namespace');
      throw UnAuthorizedException(
          'The approving enrollment does not have access'
          ' to "__manage" namespace');
    }

    if (atKey != null && namespace != null) {
      AtKey atKeyObj;
      try {
        atKeyObj = AtKey.fromString(atKey);
      } catch (e) {
        throw IllegalArgumentException('AtKey.fromString($atKey) failed: $e');
      }
      if (atKeyObj.namespace != namespace) {
        throw IllegalArgumentException(
            'AtKey namespace and passed namespace do not match');
      }
    }
    return true;
  }

  // TODO This function is overridden by EnrollVerbHandler which caused me some
  // confusion. Future maintainers beware, if this hasn't been improved.
  bool checkEnrollmentNamespaceAccess(String authorisedNamespaceAccess,
      {String enrolledNamespaceAccess = ''}) {
    return _isReadAllowed(getVerb(), authorisedNamespaceAccess) ||
        _isWriteAllowed(getVerb(), authorisedNamespaceAccess);
  }

  bool _isReadAllowed(Verb verb, String access) {
    return (verb is LocalLookup ||
            verb is Lookup ||
            verb is Config ||
            verb is NotifyFetch ||
            verb is NotifyStatus ||
            verb is NotifyList ||
            verb is Monitor ||
            verb is Scan ||
            verb is SyncFrom) &&
        EnrollmentAccess.allowsRead(access);
  }

  bool _isWriteAllowed(Verb verb, String access) {
    return (verb is Update ||
            // NOTE UpdateMeta extends Verb rather than Update, so the line
            // above does not match it.
            verb is UpdateMeta ||
            verb is Delete ||
            verb is Config ||
            verb is Notify ||
            verb is NotifyAll ||
            verb is NotifyRemove ||
            verb is Monitor ||
            verb is SyncFrom) &&
        EnrollmentAccess.allowsWrite(access);
  }

  /// An atSign body, without the leading '@'. Contains no named groups, so it
  /// is safe to interpolate more than once.
  static const String _atSignBody = Regexes.ownershipFragmentWithoutAtPrefix;

  /// The two encryption shared-key forms a client writes the first time it
  /// shares with another atSign: readable by any approved enrollment, and
  /// writable by one holding write access on at least one namespace.
  static final RegExp _rootSharedKeyRegex = RegExp(
      '^(?:@$_atSignBody:shared_key|shared_key\\.$_atSignBody)@$_atSignBody\$',
      caseSensitive: false);

  /// Namespace-less keys holding the atSign's own key material. Readable by
  /// any approved enrollment; writable only by a root enrollment
  /// ([EnrollDataStoreValue.isRootEnrollment]).
  static final RegExp _ownKeyMaterialRegex = RegExp(
      '^(?:public:(?:publickey|signing_publickey)@$_atSignBody'
      '|@$_atSignBody:signing_privatekey@$_atSignBody)\$',
      caseSensitive: false);

  /// Cached copies of another atSign's public key material. Readable by any
  /// approved enrollment; writes are decided by the namespace check.
  static final RegExp _cachedKeyMaterialRegex = RegExp(
      '^cached:public:(?:publickey|signing_publickey)@$_atSignBody\$',
      caseSensitive: false);

  /// Namespace-less keys writable only by a root enrollment. Reads are decided
  /// by the namespace check.
  static final RegExp _rootOnlyWritableKeyRegex = RegExp(
      '^(?:privatekey:[^\\s]+'
      '|private:blocklist@$_atSignBody'
      '|configkey)\$',
      caseSensitive: false);

  /// Whether this connection may perform atSign-level privileged operations,
  /// as opposed to the key-level ones [isAuthorized] decides.
  ///
  /// True for a CRAM connection, or for an approved root enrollment.
  Future<bool> isRootPrivilegedConnection(
      InboundConnectionMetadata inboundConnectionMetadata) async {
    if (isCramConnection(inboundConnectionMetadata)) {
      return true;
    }
    final enrollmentId = inboundConnectionMetadata.enrollmentId;
    if (enrollmentId == null) {
      return false;
    }
    final EnrollDataStoreValue? enroll = await resolveEnrollment(enrollmentId);
    if (enroll == null ||
        enroll.approval?.state != EnrollmentStatus.approved.name) {
      return false;
    }
    return enroll.isRootEnrollment;
  }

  /// Whether the verb being handled mutates a key.
  bool isMutatingVerb() {
    final Verb verb = getVerb();
    return verb is Update ||
        verb is UpdateMeta ||
        verb is Delete ||
        verb is Notify ||
        verb is NotifyAll ||
        verb is NotifyRemove;
  }

  /// Whether this verb puts a CALLER-CHOSEN value into the keystore, as
  /// distinct from [isMutatingVerb], which also covers removal.
  bool isWritingVerb() {
    final Verb verb = getVerb();
    return verb is Update || verb is UpdateMeta;
  }

  /// Decides a namespace-less key for an enrollment, or returns null to let
  /// the namespace check decide.
  bool? _decideRootKey(
      String? atKey, EnrollDataStoreValue enrollDataStoreValue) {
    if (atKey == null) {
      return null;
    }
    // NOTE folded with the keystore's own fold, so the regexes below test the
    // string the store holds.
    final String key = canonicalAtKey(atKey);

    if (_rootSharedKeyRegex.hasMatch(key)) {
      if (isMutatingVerb()) {
        return enrollDataStoreValue.namespaces.values
            .any(EnrollmentAccess.allowsWrite);
      }
      return true;
    }
    if (_cachedKeyMaterialRegex.hasMatch(key)) {
      return isMutatingVerb() ? null : true;
    }
    final bool isOwnKeyMaterial = _ownKeyMaterialRegex.hasMatch(key);
    if (isOwnKeyMaterial || _rootOnlyWritableKeyRegex.hasMatch(key)) {
      if (isMutatingVerb()) {
        // NOTE no enrollment may mutate these two, whatever it holds:
        // writing one mints an identity rather than serving one.
        if (isWritingVerb() &&
            (key == AtConstants.atCramSecret ||
                key == AtConstants.atCramSecretDeleted)) {
          return false;
        }
        if (key == AtConstants.atPkamPublicKey) {
          return false;
        }
        return enrollDataStoreValue.isRootEnrollment;
      }
      return isOwnKeyMaterial ? true : null;
    }
    return null;
  }

  /// Whether [passcode] is a live SPP or OTP. A valid OTP is removed from the
  /// keystore so it cannot be reused; an SPP is not.
  Future<bool> isPasscodeValid(String? passcode) async {
    if (passcode == null) {
      return false;
    }
    String passcodeKey = OtpVerbHandler.passcodeKey(passcode, isSpp: true);
    if (!await keyStore.exists(passcodeKey)) {
      // NOTE falls back to the namespace-less form an older client stored.
      passcodeKey =
          'private:spp${AtSecondaryServerImpl.getInstance().currentAtSign}';
    }
    try {
      AtData? sppAtData = await keyStore.get(passcodeKey);
      if (sppAtData?.data?.toLowerCase() == passcode.toLowerCase()) {
        if (SecondaryUtil.isActiveKey(sppAtData)) {
          return true;
        } else {
          logger.finest(
              'SPP found in KeyStore but has expired. Validating as OTP');
        }
      }
    } on KeyNotFoundException {
      logger.finest('No SPP found in KeyStore. Validating as OTP');
    }

    String otpKey = OtpVerbHandler.passcodeKey(passcode, isSpp: false);
    if (!await keyStore.exists(otpKey)) {
      otpKey =
          'private:${passcode.toLowerCase()}${AtSecondaryServerImpl.getInstance().currentAtSign}';
    }

    AtData? otpAtData;
    try {
      otpAtData ??= await keyStore.get(otpKey);
    } on KeyNotFoundException {
      return false;
    }

    bool isOTPValid = SecondaryUtil.isActiveKey(otpAtData);
    await keyStore.remove(otpKey);

    return isOTPValid;
  }

  /// Reads the one-time challenge `from:` stored under [storedSecretId],
  /// removes it, and returns its value only if the record is still live.
  ///
  /// Returns null when the challenge is absent, unreadable or expired; the
  /// removal happens either way.
  Future<String?> consumeChallenge(String storedSecretId) async {
    AtData? challenge;
    try {
      challenge = await keyStore.get(storedSecretId);
    } on KeyNotFoundException {
      return null;
    } catch (e) {
      logger.warning('Failed to read challenge $storedSecretId: $e');
      return null;
    }
    try {
      await keyStore.remove(storedSecretId);
    } catch (e) {
      logger.warning('Failed to immediately remove $storedSecretId');
    }
    if (!SecondaryUtil.isActiveKey(challenge)) {
      return null;
    }
    return challenge?.data;
  }
}
