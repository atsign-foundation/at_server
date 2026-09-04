import 'dart:collection';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_access.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
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

  /// Parses a given command against a corresponding verb syntax
  /// @returns  Map containing  key(group name from syntax)-value from the command
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
    // Closes an already-authenticated connection whose enrollment has left
    // approved. A new connection carries no enrollmentId yet, so this does not
    // terminate an unauthenticated one running a PKAM verb.
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
  ///
  /// These are the codes `pkam` refuses an authentication with, so a client
  /// cut off mid-session reads the reason a fresh connection would be given.
  /// A state with no code of its own, an unreadable approval included,
  /// reports AT0028.
  static String _closeCodeForState(String? state) {
    if (state == EnrollmentStatus.denied.name) return 'AT0025';
    if (state == EnrollmentStatus.pending.name) return 'AT0026';
    if (state == EnrollmentStatus.revoked.name) return 'AT0027';
    return 'AT0028';
  }

  /// When authenticated with the APKAM keys, checks if the enrollment is active.
  /// Returns true if the enrollment is active; otherwise, returns false.
  Future<(bool, Response)> _verifyIfEnrollmentIsActive(
      Response response, AtConnectionMetaData atConnectionMetadata) async {
    // A connection with no enrollment id stands over no enrollment record, so
    // there is no approval state to read. Only CRAM is in that company: a
    // legacy `pkam:` carries `primary`, so this check closes a legacy
    // connection too once `primary` leaves approved.
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
      // A connection may continue only for as long as its enrollment could
      // still authenticate: `pkam` admits an APKAM connection on `approved`
      // and refuses every other state.
      //
      // Closed rather than merely denied, because per-verb denial is only as
      // complete as the least careful handler. A verb deciding access its own
      // way would go on serving a revoked caller for as long as it held the
      // socket; closing states the rule once.
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
      // An expired enrollment is removed from the keystore, so it surfaces
      // here as KeyNotFoundException.
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
  /// A `public:` key is exempt for READS only, which is what [isMutating]
  /// distinguishes. `public:_apsk.<id>.a.__e@` is the APKAM signing key and
  /// is world-readable by design, but whoever can WRITE it chooses the
  /// algorithms and key ids a verifier trusts, so that is forgery rather than
  /// vandalism. Without the mutating case a caller holding `*` and no
  /// `__manage` would reach another enrollment's signing key through the
  /// wildcard fallback below.
  static bool isForeignPerEnrollmentReservedKey(
      String atKey, String? enrollmentId,
      {bool isMutating = false}) {
    if (!isMutating && atKey.startsWith('public:')) {
      return false;
    }
    final match = _perEnrollmentReservedKeyRegex.firstMatch(atKey);
    if (match == null) {
      return false;
    }
    // The owning id comes out of a CALLER-supplied atKey, so it is folded to
    // the keystore's own form before comparison with the connection's id,
    // which is already in that form. Unfolded, the owner named by the
    // spelling and the owner of the record the keystore would serve can
    // differ, and a caller's own key spelled non-canonically reads as
    // foreign. Folding cannot widen access: it is how the keystore decides
    // which record a key names, so a key that compares equal is the caller's.
    return EnrollmentManager.canonicalEnrollmentId(
            match.namedGroup('EnId')!) !=
        enrollmentId;
  }

  /// Whether [atKey]'s namespace is the enrollment-manage namespace
  /// (`__manage`), i.e. an enrollment record or its encrypted key material
  /// (PEK/SEK).
  static bool isEnrollManageKey(String atKey) {
    return atKey.contains('.${EnrollmentConstants.enrollManageNamespace}@');
  }

  /// Whether this connection may retrieve, modify or delete data in a
  /// namespace: "r" or "rw" for a lookup or local lookup, "rw" for an update
  /// or delete.
  ///
  /// True for a connection with no enrollment id, which stands over no
  /// enrollment record, and for an approved enrollment holding enough access
  /// on the namespace. False when the enrollment record is absent or not
  /// approved, when it holds nothing or too little for the operation, and
  /// when the key carries no namespace and the enrollment has no `*`.
  ///
  /// Uses [namespace] when passed, otherwise the namespace of [atKey].
  Future<bool> isAuthorized(InboundConnectionMetadata inboundConnectionMetadata,
      {String? atKey,
      String? namespace,
      String enrolledNamespaceAccess = '',
      String operation = ''}) async {
    final enrollmentId = inboundConnectionMetadata.enrollmentId;
    // Ahead of the short circuit below, because the connection it exists for
    // is the one that carries no enrollment id.
    refuseFlatCredentialWrite(inboundConnectionMetadata, atKey);
    if (isCramConnection(inboundConnectionMetadata)) {
      return true;
    }
    // Not CRAM and carrying no enrollment: nothing to judge by, so refused.
    // Only cram: leaves an authenticated connection without an id, and an
    // unauthenticated connection reaching a check answers the same way.
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

  /// The ONE gate on writing the flat legacy credential,
  /// `privatekey:at_pkam_publickey`: refused for every connection, whatever
  /// it holds, with the single exception below.
  ///
  /// Called from [isAuthorized] ahead of its null-id short circuit, because a
  /// connection carrying no enrollment id is authorised for everything else
  /// before any key is examined. So this decides for CRAM as well as for
  /// every enrollment, `primary` included. Scoped to the writing verbs,
  /// `update` and `update:meta`, which `update:json` and `batch:` both
  /// re-dispatch into.
  ///
  /// No connection may write it because a legacy `pkam:` is verified against
  /// it outside every enrollment record, and a key found there is absorbed
  /// into `primary` on the next legacy login. A caller that installs a key it
  /// holds therefore rotates the owner's own credential onto itself, and
  /// survives its own revocation as the owner.
  ///
  /// THE ONE EXCEPTION is a CRAM connection sending a plain `update`, which
  /// is how a fresh atSign is given its first keypair. Even then no flat key
  /// is written: `UpdateVerbHandler` redirects the value into the `primary`
  /// enrollment, which is why `update:meta`, a write with no value to
  /// redirect, is not exempt. CRAM alone decides it, in every mode, with no
  /// part played by [AtSecondaryConfig.testingMode]: the caller holds the
  /// secret the atSign was created with, and an `enroll:request` on that
  /// connection is auto-approved with `*:rw` and `__manage:rw`, exactly what
  /// `primary` holds, so admitting the install grants nothing the caller
  /// could not already give itself. Key uniqueness still applies.
  ///
  /// [atKey] is compared as the keystore folds it, so a spelling that would
  /// fold onto this record cannot slip past. Throws [UnAuthorizedException];
  /// returns for any other key and for any non-writing verb.
  /// Whether [md] is a CRAM-authenticated connection: the one kind that
  /// holds the atSign itself rather than an enrollment, and is authorised for
  /// everything. Authentication is part of it because `authType` outlives
  /// it: a later failed `pkam:` clears `isAuthenticated` and nothing else.
  static bool isCramConnection(InboundConnectionMetadata md) =>
      md.isAuthenticated && md.authType == AuthType.cram;

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
  ///
  /// Companion to [isAuthorizedSync]: a caller deciding many entries against
  /// one enrollment resolves once here, then calls [isAuthorizedSync] in a
  /// synchronous inner loop.
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
  /// fetched by [resolveEnrollment]. Hot-path companion to [isAuthorized] for
  /// callers deciding many entries against one enrollment, such as sync's
  /// commit-log walk.
  ///
  /// A CRAM connection ([cram], see [isCramConnection]) gets full access.
  /// Otherwise a null [enrollmentId] or a null [enrollDataStoreValue] (an
  /// unresolvable record) gets none. A namespace-less [atKey] is decided by [_decideRootKey],
  /// which may defer to the namespace check; everything else is decided by
  /// the enrollment's namespace access.
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

    // A per-enrollment reserved namespace (<id>.a|r|d.__e) is private to the
    // enrollment that owns it, so any OTHER enrollment is denied, including
    // one holding '*:rw' that would otherwise reach it via the wildcard
    // fallback below. Public keys are exempt for reads only; see
    // isForeignPerEnrollmentReservedKey.
    if (atKey != null &&
        isForeignPerEnrollmentReservedKey(atKey, enrollmentId,
            isMutating: isMutatingVerb())) {
      return false;
    }

    // Namespace-less keys carry no namespace an enrollment can hold. A null
    // verdict defers the decision to the namespace check below.
    final bool? rootKeyVerdict = _decideRootKey(atKey, enrollDataStoreValue);
    if (rootKeyVerdict != null) {
      return rootKeyVerdict;
    }

    // AtKey.fromString throws on some key shapes that occur in the keystore
    // and the commit log, raising Errors as well as Exceptions, so catch
    // everything. An unresolved namespace falls to the '*' check below.
    String keyWithNamespace = '';
    if ((namespace == null || namespace.isEmpty) && atKey != null) {
      try {
        AtKey atKeyObj = AtKey.fromString(atKey);
        namespace = atKeyObj.namespace;
        // Built only when the key carries a namespace.
        if (namespace != null && namespace.isNotEmpty) {
          keyWithNamespace = '${atKeyObj.key}.$namespace';
        }
      } catch (_) {
        namespace = null;
      }
    }

    // The __atserver namespace holds data the atServer publishes for every
    // client to read, such as "another atSign's public key changed" events,
    // so every enrollment reads it and none writes it.
    if (!enrollDataStoreValue.namespaces
        .containsKey(AtConstants.atServerReservedNamespace)) {
      enrollDataStoreValue.namespaces[AtConstants.atServerReservedNamespace] =
          'r';
    }

    // Every enrollment has rw on the namespace unique to itself. No other
    // enrollment reaches it except for public data, which the foreign
    // per-enrollment check above enforces.
    enrollDataStoreValue.namespaces[enrollmentReservedNamespace(enrollmentId)] =
        'rw';

    // $1 is the matched namespace, $2 the access held on it.
    (String, String?) authorizedNamespace = _checkForNamespaceAuthorization(
        enrollDataStoreValue, namespace, keyWithNamespace);

    if (authorizedNamespace.$1.isEmpty ||
        (authorizedNamespace.$2 == null || authorizedNamespace.$2!.isEmpty)) {
      return false;
    }

    // The __manage namespace holds enrollment records and per-enrollment
    // encrypted key material (PEK/SEK). It is reachable only by an enrollment
    // holding __manage EXPLICITLY, and then only via otp/enroll/monitor,
    // never a generic data verb. An enrollment that reached a __manage key
    // through the '*' wildcard fallback is denied outright, so '*:rw' cannot
    // launder __manage into '*' and bypass this guard.
    if (namespace == EnrollmentConstants.enrollManageNamespace ||
        authorizedNamespace.$1 == EnrollmentConstants.enrollManageNamespace) {
      final bool holdsManageNamespaceExplicitly =
          authorizedNamespace.$1 == EnrollmentConstants.enrollManageNamespace;
      final String? callerAccess = authorizedNamespace.$2;
      // A caller may not act on a __manage grant stronger than its own.
      // [enrolledNamespaceAccess] is the access the TARGET holds here, and is
      // non-empty only where the caller must demonstrate authority over
      // ANOTHER enrollment's grants: approve, deny, revoke, unrevoke, fetch
      // and delete each walk the target's namespaces and ask this once per
      // entry. So '__manage:rw' is reachable only by a holder of
      // '__manage:rw', and a holder of '__manage:r' reaches only
      // '__manage:r', reads included, since a caller with no claim to
      // revoke or delete an administrator has none to read its record
      // either.
      //
      // The comparison has to happen here rather than in
      // checkEnrollmentNamespaceAccess below, because the verbs that reach
      // __manage are absent from that method's verb lists entirely.
      //
      // An empty [enrolledNamespaceAccess] is not a grant: it is a caller
      // reaching a __manage KEY, for which read access is enough.
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
  /// A namespace matches an enrolled one it is a suffix-segment of, so
  /// "data.orders.myapp" matches an enrolled "orders.myapp". Failing that, a
  /// `*` in the enrollment matches anything.
  ///
  /// Returns an empty string and `null` when nothing matches: with an
  /// enrollment holding only "orders.myapp", "data.myapp" is unauthorised,
  /// while the same enrollment holding `*` as well answers ("*", "rw").
  (String, String?) _checkForNamespaceAuthorization(
      EnrollDataStoreValue enrollDataStoreValue,
      String? namespace,
      String? keyWithNamespace) {
    String authorisedNamespace = '';
    String? access;
    // Only a key that carries a namespace is matched against the enrolled
    // namespaces.
    if (namespace != null && namespace.isNotEmpty) {
      for (String enrolledNamespace in enrollDataStoreValue.namespaces.keys) {
        if ('.$namespace'.endsWith('.$enrolledNamespace')) {
          authorisedNamespace = enrolledNamespace;
          break;
        }
      }
    }

    // AtKey.namespace returns only the LAST segment of a dotted namespace
    // ('bar' for 'foo.bar'), which cannot be matched against an enrolled
    // multi-segment namespace. Matching the whole key instead recovers it.
    // keyWithNamespace is empty when the key carries no namespace.
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
    // '*' authorises every namespace.
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
    // Only an approved enrollment may act.
    if (enrollDataStoreValue.approval?.state !=
        EnrollmentStatus.approved.name) {
      return false;
    }
    // Approving, denying and revoking an enrollment request all need
    // "__manage".
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
            // `update:meta` writes metadata (ttl, ttb, ccd), so it is gated
            // exactly like `update`. Listed explicitly because `UpdateMeta`
            // extends `Verb` rather than `Update`, so the line above does
            // not match it.
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

  /// An atSign body, without the leading '@'. Reuses at_commons' own charset
  /// (word characters, '-', '_' and emoji; 1..55) so emoji atSigns stay in
  /// lockstep with AtKey parsing. Contains no named groups, so it is safe to
  /// interpolate more than once.
  static const String _atSignBody = Regexes.ownershipFragmentWithoutAtPrefix;

  /// Namespace-less keys that any approved enrollment may read and write: the
  /// two encryption shared-key forms a client writes the first time it shares
  /// with another atSign.
  ///
  /// Anchored at both ends, so it matches a whole key rather than a substring.
  static final RegExp _rootSharedKeyRegex = RegExp(
      '^(?:@$_atSignBody:shared_key|shared_key\\.$_atSignBody)@$_atSignBody\$',
      caseSensitive: false);

  /// Namespace-less keys holding the atSign's own key material. Readable by
  /// any approved enrollment; writable only by a root enrollment
  /// ([EnrollDataStoreValue.isRootEnrollment]).
  ///
  /// Reads stay open because sync force-includes these keys
  /// (`alwaysIncludeInSync` in utils/regex_util.dart admits any namespace-less
  /// `public:` key) and ANDs the result with this check.
  static final RegExp _ownKeyMaterialRegex = RegExp(
      '^(?:public:(?:publickey|signing_publickey)@$_atSignBody'
      '|@$_atSignBody:signing_privatekey@$_atSignBody)\$',
      caseSensitive: false);

  /// Cached copies of another atSign's public key material. Readable by any
  /// approved enrollment; writes are decided by the namespace check rather
  /// than by a root enrollment, since the data is public at its origin and
  /// the cached copy is local.
  static final RegExp _cachedKeyMaterialRegex = RegExp(
      '^cached:public:(?:publickey|signing_publickey)@$_atSignBody\$',
      caseSensitive: false);

  /// Namespace-less keys writable only by a root enrollment. Reads are decided
  /// by the namespace check, so sync membership is unaffected.
  ///
  /// The whole `privatekey:` prefix is covered: its members hold the server's
  /// own credentials and internal state, and the server writes them.
  static final RegExp _rootOnlyWritableKeyRegex = RegExp(
      '^(?:privatekey:[^\\s]+'
      '|private:blocklist@$_atSignBody'
      '|configkey)\$',
      caseSensitive: false);

  /// Whether this connection may perform atSign-level privileged operations,
  /// as opposed to the key-level ones [isAuthorized] decides.
  ///
  /// True for a CRAM connection, or for an approved root enrollment. An
  /// enrollment's namespace map is only what the client asked for, so
  /// approval state is part of the check.
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
  ///
  /// Not derived from [_isWriteAllowed]: Config, Monitor and SyncFrom appear
  /// in both that list and [_isReadAllowed], which would classify sync as a
  /// write. [UpdateMeta] is listed explicitly because it extends `Verb`
  /// rather than `Update`.
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
  ///
  /// The distinction matters for the keys that mint an identity: installing a
  /// chosen value at one hands the caller a credential, while removing what
  /// is there does not, and removing some of them is legitimate (onboarding
  /// deletes the CRAM secret once PKAM is established).
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
    // Matched against the form the keystore writes, using the keystore's own
    // fold rather than a copy of it: the regexes below decide root-only
    // access, so a fold that drifted from the store's would test a string the
    // store does not hold.
    final String key = canonicalAtKey(atKey);

    if (_rootSharedKeyRegex.hasMatch(key)) {
      return true;
    }
    // Cached public keys: readable by any enrollment, written per namespace.
    if (_cachedKeyMaterialRegex.hasMatch(key)) {
      return isMutatingVerb() ? null : true;
    }
    final bool isOwnKeyMaterial = _ownKeyMaterialRegex.hasMatch(key);
    if (isOwnKeyMaterial || _rootOnlyWritableKeyRegex.hasMatch(key)) {
      if (isMutatingVerb()) {
        // NO enrollment may mutate these two, whatever it holds, because
        // writing one MINTS AN IDENTITY rather than serving one. Every other
        // key in this branch is decided by what the enrollment holds.
        //
        // A WRITE of the PKAM key never reaches here: it is decided for
        // every connection by [refuseFlatCredentialWrite], ahead of the
        // null-id short circuit. What this line still decides for it is
        // deletion by an enrollment.
        //
        // Installing a CRAM secret, or its tombstone, is refused for the
        // same reason: a caller that plants a secret it knows can
        // authenticate as the owner carrying no enrollment id, so revoking
        // the enrollment that planted it takes nothing back, and a caller
        // that plants the tombstone permanently disables CRAM replanting,
        // the atSign's last recovery route once its roots are revoked.
        // WRITES only, though: onboarding deletes the CRAM secret once PKAM
        // is established, and that is a root enrollment's job.
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
      // Own key material stays readable; the rest is decided below.
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
      // The namespaced SPP key is absent, so fall back to the namespace-less
      // form an older client stored.
      passcodeKey =
          'private:spp${AtSecondaryServerImpl.getInstance().currentAtSign}';
    }
    try {
      AtData? sppAtData = await keyStore.get(passcodeKey);
      // An SPP is stored as the VALUE under a fixed key, whereas an OTP is
      // part of its own key and its stored data is irrelevant.
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
      // As above: fall back to the namespace-less form.
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
    // An OTP is spent on use; an SPP is not, and never reaches here.
    await keyStore.remove(otpKey);

    return isOTPValid;
  }

  /// Reads the one-time challenge `from:` stored under [storedSecretId],
  /// removes it, and returns its value only if the record is still live.
  ///
  /// The removal is unconditional, whatever the caller goes on to decide, so
  /// a challenge buys exactly one verification attempt. Left in place on a
  /// failure it would be a retry oracle, letting a caller try signature after
  /// signature against one challenge.
  ///
  /// Liveness is asked here because no keystore backend applies expiry on
  /// read: `get` returns a record whose `expiresAt` has passed, and the only
  /// other enforcement is a background sweep on its own schedule.
  ///
  /// Returns null when the challenge is absent, unreadable or expired. A
  /// caller must treat all three as it treats a bad signature, so the wire
  /// cannot be used to tell them apart.
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
      // A challenge that cannot be removed must still not be honoured, so the
      // liveness check below decides the outcome rather than a throw here.
      logger.warning('Failed to immediately remove $storedSecretId');
    }
    if (!SecondaryUtil.isActiveKey(challenge)) {
      return null;
    }
    return challenge?.data;
  }
}
