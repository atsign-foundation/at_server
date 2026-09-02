import 'dart:collection';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
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
    // This check verifies whether the enrollment is active on the already APKAM authenticated existing connection
    // and terminates if the enrollment is expired.
    // At this stage, the enrollmentId is not set to the InboundConnectionMetadata for the new connections.
    // This will not terminate an un-authenticated connection when attempting to execute a PKAM verb with an expired enrollmentId.
    (bool, Response) isEnrollmentActive =
        await _verifyIfEnrollmentIsActive(response, atConnectionMetadata);
    if (isEnrollmentActive.$1 == false) {
      await atConnection.close();
      return isEnrollmentActive.$2;
    }
    try {
      // Parse the command
      var verbParams = parse(command);
      // TODO This is not ideal. Would be better to make it so that processVerb takes command as an argument also.
      verbParams[paramFullCommandAsReceived] = command;
      // Syntax is valid. Process the verb now.
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

  /// When authenticated with the APKAM keys, checks if the enrollment is active.
  /// Returns true if the enrollment is active; otherwise, returns false.
  Future<(bool, Response)> _verifyIfEnrollmentIsActive(
      Response response, AtConnectionMetaData atConnectionMetadata) async {
    // When authenticated with legacy keys, enrollment id is null. APKAM expiry does not
    // apply to such connections. Therefore, return true.
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
      // If the enrollment status is expired, then the enrollment is not active. Return false.
      if (enrollDataStoreValue.approval?.state ==
          EnrollmentStatus.expired.name) {
        logger.severe(
            'The enrollment id: ${atConnectionMetadata.enrollmentId} is expired. Closing the connection');
        response
          ..isError = true
          ..errorCode = 'AT0028'
          ..errorMessage =
              'The enrollment id: ${(atConnectionMetadata).enrollmentId} is expired. Closing the connection';
        return (false, response);
      }
      // The expired enrollments are removed from the keystore. In such cases, KeyNotFoundException is
      // thrown. Return false.
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

  /// Return the instance of the current verb
  ///@return instance of [Verb]
  Verb getVerb();

  /// Process the given command using verbParam and requesting atConnection. Sets the data in response.
  ///@param response - response of the command
  ///@param verbParams - contains key-value mapping of groups names from verb syntax
  ///@param atConnection - Requesting connection
  Future<void> processVerb(Response response,
      HashMap<String, String?> verbParams, InboundConnection atConnection);

  static String enrollmentReservedNamespace(String enrollmentId) {
    return '$enrollmentId.${EnrollmentConstants.perEnrollmentApproved}';
  }

  /// Matches a per-enrollment reserved-namespace key (`<EnId>.a|r|d.__e@…`),
  /// capturing the owning enrollment id in the `EnId` group. Compiled once.
  static final RegExp _perEnrollmentReservedKeyRegex =
      RegExp(EnrollmentConstants.regexForPerEnrollmentNamespaces);

  /// Whether [atKey] lives in a per-enrollment reserved namespace
  /// (`<id>.a|r|d.__e`) owned by an enrollment *other than* [enrollmentId].
  ///
  /// A public key is exempt for READS only — `public:_apsk.<id>.a.__e@` is the
  /// APKAM signing key, and it is world-readable by design. It is NOT exempt
  /// for writes or deletes, which is what [isMutating] distinguishes: being
  /// readable by everyone is not a reason to be writable by anyone. A caller
  /// holding `*` and no `__manage` would otherwise reach another enrollment's
  /// published signing key — the namespace resolves to one nothing in its map
  /// matches, the wildcard fallback supplies `rw`, and the `__manage` guard
  /// is skipped because the namespace is not `__manage`. Whoever can write
  /// that record controls both the algorithm set and the key ids a verifier
  /// trusts, so it is forgery rather than vandalism.
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
    return match.namedGroup('EnId') != enrollmentId;
  }

  /// Whether [atKey]'s namespace is the enrollment-manage namespace
  /// (`__manage`) — i.e. an enrollment record or its encrypted key material
  /// (PEK/SEK).
  static bool isEnrollManageKey(String atKey) {
    return atKey.contains('.${EnrollmentConstants.enrollManageNamespace}@');
  }

  /// Verifies whether the current connection has permission to
  /// modify, delete, or retrieve the data in a given namespace.
  ///
  /// The connection's enrollment should be in an approved state.
  ///
  /// To execute a data retrieval (lookup or local lookup), the connection
  /// must have "r" or "rw" (read / read-write) access for the namespace.
  ///
  /// For update or delete, the connection must have "rw" (read-write) access.
  ///
  /// Returns true if
  /// - EITHER the connection has no enrollment ID (i.e. it was the first enrolled
  ///   app)
  /// - OR the connection has the required read or read-write
  ///   permissions to execute lookup/local-lookup or update/delete operations
  ///   respectively
  ///
  /// The connection will be deemed not to have permission if any of the
  /// following are true:
  ///  - the enrollment key is not present in the keystore.
  ///  - the enrollment is not in "approved" state
  ///  - the connection has no permissions for this namespace
  ///  - the connection has insufficient permission for this namespace
  ///    (for example, has "r" but needs "rw" for a delete operation)
  ///  - If enrollment is a part of "global" or "manage" namespace
  ///  - the connection does not have access to * namespace and key has no namespace
  /// Use [namespace] if passed, otherwise retrieve namespace from [atKey]. Return false if no [namespace] or [atKey] is set.
  Future<bool> isAuthorized(InboundConnectionMetadata inboundConnectionMetadata,
      {String? atKey,
      String? namespace,
      String enrolledNamespaceAccess = '',
      String operation = ''}) async {
    final enrollmentId = inboundConnectionMetadata.enrollmentId;
    // A connection with no enrollment id has full permissions. Namespace-less
    // keys are decided in isAuthorizedSync, against the resolved enrollment.
    if (enrollmentId == null) {
      return true;
    }
    final enroll = await resolveEnrollment(enrollmentId);
    return isAuthorizedSync(enroll, enrollmentId,
        atKey: atKey,
        namespace: namespace,
        enrolledNamespaceAccess: enrolledNamespaceAccess,
        operation: operation);
  }

  /// Fetches the enrollment record for [enrollmentId] from the
  /// enrollment manager. Returns `null` if the record cannot be
  /// found ([KeyNotFoundException]); callers treat that as
  /// "deny all".
  ///
  /// Companion to [isAuthorizedSync] — callers that need to authorize
  /// many entries against a single enrollment context resolve once via
  /// this method, then call [isAuthorizedSync] in a sync inner loop.
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

  /// Synchronous per-entry authorization check against a pre-fetched
  /// [enrollDataStoreValue]. Hot-path companion to [isAuthorized] for
  /// callers that decide many entries against a single enrollment
  /// context (e.g. sync's commit-log walk) — resolve once via
  /// [_resolveEnrollment], then call this for each candidate atKey.
  ///
  /// Input states:
  ///   - [enrollmentId] is null → legacy PKAM, full access → true
  ///   - [enrollDataStoreValue] is null → enrollment record unresolvable
  ///     ([KeyNotFoundException] from [_resolveEnrollment]) → false
  ///   - [atKey] is a root key (no grantable namespace) → decided by
  ///     [_decideRootKey], which may defer to the namespace check
  ///   - otherwise → namespace-access decision based on the enrollment
  bool isAuthorizedSync(
      EnrollDataStoreValue? enrollDataStoreValue, String? enrollmentId,
      {String? atKey,
      String? namespace,
      String enrolledNamespaceAccess = '',
      String operation = ''}) {
    if (enrollmentId == null) {
      return true;
    }
    if (enrollDataStoreValue == null) {
      return false;
    }

    bool isValidEnrollment = _applyEnrollmentValidations(
        enrollDataStoreValue, operation, atKey, namespace);
    if (!isValidEnrollment) {
      return isValidEnrollment;
    }

    // A per-enrollment reserved namespace (<id>.a|r|d.__e) is private to the
    // enrollment that owns it. Deny any *other* enrollment — including one with
    // '*:rw', which would otherwise reach it via the wildcard fallback below.
    // (Public keys are exempt for READS only; see
    // isForeignPerEnrollmentReservedKey.) A connection with no enrollmentId
    // already short-circuited to `true` above, so this does not alter
    // owner/legacy access.
    if (atKey != null &&
        isForeignPerEnrollmentReservedKey(atKey, enrollmentId,
            isMutating: isMutatingVerb())) {
      return false;
    }

    // Namespace-less keys carry no namespace an enrollment can hold. A null
    // verdict defers the decision to the namespace check below.
    final bool? rootKeyVerdict =
        _decideRootKey(atKey, enrollDataStoreValue, enrollmentId);
    if (rootKeyVerdict != null) {
      return rootKeyVerdict;
    }

    // If namespace is null or empty, fetch namespace from AtKey.
    //
    // AtKey.fromString throws on some key shapes that occur in the keystore and
    // the commit log, raising Errors as well as Exceptions, so catch
    // everything. An unresolved namespace is decided by the '*' fallback below.
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

    // All enrollments should have access to read from the __atserver
    // namespace but not to write to it.
    // This namespace is reserved for the atServer to store data which
    // should be available for read by all clients. The initial driver for
    // creating this reserved namespace was that we needed a place to
    // store information about "another atSign's public key changed" events.
    //
    // Unit tests to assert this are in scan_verb_test.dart
    if (!enrollDataStoreValue.namespaces
        .containsKey(AtConstants.atServerReservedNamespace)) {
      enrollDataStoreValue.namespaces[AtConstants.atServerReservedNamespace] =
          'r';
    }

    // All enrollments have rw access to a namespace unique to their enrollment.
    // Other enrollments have NO access to it, except to public data — a '*:rw'
    // enrollment used to reach it via the wildcard fallback, but that
    // cross-enrollment reach is now denied above (see the foreign per-enrollment
    // check). Own-enrollment access is granted by the line below.
    //
    // Unit tests to assert this are in update_verb_test.dart and
    // enrollment_authz_tightening_test.dart
    enrollDataStoreValue.namespaces[enrollmentReservedNamespace(enrollmentId)] =
        'rw';

    // Checks for namespace authorisation
    // In the authorizedNamespace, the first parameter represents the namespace and second parameter represents the
    // access of the namespace.
    (String, String?) authorizedNamespace = _checkForNamespaceAuthorization(
        enrollDataStoreValue, namespace, keyWithNamespace);

    // "authorizedNamespace.$1" represents the namespace and "authorizedNamespace.$2" represents
    // the access of the namespace.
    if (authorizedNamespace.$1.isEmpty ||
        (authorizedNamespace.$2 == null || authorizedNamespace.$2!.isEmpty)) {
      return false;
    }

    // The __manage namespace holds enrollment records and per-enrollment
    // encrypted key material (PEK/SEK). It is reachable only by an enrollment
    // that holds __manage *explicitly*, and then only via otp/enroll/monitor —
    // never a generic data verb (update/delete/lookup/…). An enrollment that
    // reaches a __manage key through the '*' wildcard fallback (i.e. without an
    // explicit __manage grant) is denied outright, so '*:rw' cannot launder
    // __manage into '*' and bypass this guard.
    if (namespace == EnrollmentConstants.enrollManageNamespace ||
        authorizedNamespace.$1 == EnrollmentConstants.enrollManageNamespace) {
      final bool holdsManageNamespaceExplicitly =
          authorizedNamespace.$1 == EnrollmentConstants.enrollManageNamespace;
      // ignore: experimental_member_use
      return holdsManageNamespaceExplicitly &&
          (getVerb() is Otp || getVerb() is Enroll || getVerb() is Monitor) &&
          (authorizedNamespace.$2 == 'r' || authorizedNamespace.$2 == 'rw');
    }
    return checkEnrollmentNamespaceAccess(authorizedNamespace.$2!,
        enrolledNamespaceAccess: enrolledNamespaceAccess);
  }

  /// Verifies if the provided `namespace` has super set access based on the
  /// namespaces defined in `enrollDataStoreValue`.
  ///
  /// This function checks if the given `namespace` is a subset or exact match
  /// of any namespace in the `enrollDataStoreValue`. If so, it returns the
  /// matched namespace and its access level. If `enrollDataStoreValue`
  /// contains a wildcard (`*`), it grants access to all namespaces.
  ///
  /// Example:
  /// - Given approving app does not have access to '*' namespace.
  ///   - If enrolling `namespace` is "orders.myapp" and approving app namespace is "orders.myapp", then ("orders.myapp", "rw") is returned.
  ///   - If enrolling `namespace` is "data.orders.myapp" and approving app namespace is "orders.myapp", then ("orders.myapp", "rw")  is returned.
  ///   - If enrolling `namespace` is "data.myapp" and approving app namespace is "orders.myapp", then and empty string, null are returned,
  ///     representing no matching authorised namespace found (Since enrollment does not have access to '*' namespace).
  ///
  /// - Given approving app does not have access to '*' namespace.
  ///   - If enrolling `namespace` is "data.myapp" and approving app namespace is "orders.myapp", then ("*", "rw") is returned.
  ///
  /// - Parameters:
  ///   - enrollDataStoreValue: The `EnrollDataStoreValue` containing namespaces and their access levels.
  ///   - namespace: The namespace to be verified.
  ///
  /// - Returns: A tuple containing the authorised namespace and its access level.
  ///   If no matching namespace is found, it returns an empty string and `null` for access.
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

    /// If the namespace contains a period ('.'), AtKey(key).namespace will return only the last segment of the namespace.
    /// For example, if the namespace is 'foo.bar', AtKey(key).namespace will return 'bar'. In such cases, authorisedNamespace
    /// cannot be cannot be fetched due to incomplete namespace.
    /// Currently, to authorize such keys, use the full key along with the namespace to perform the authorization check.
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
    // If enrolledDataStore value contains *, it means at is authorised for all namespaces
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
    // Only approved enrollmentId is authorised to perform operations. Return false for enrollments
    // which are not approved.
    if (enrollDataStoreValue.approval?.state !=
        EnrollmentStatus.approved.name) {
      return false;
    }
    // Only the enrollmentId with access to "__manage" namespace can approve, deny, revoke
    // an enrollment request. If enrollmentId does not have access to "__manage" access, then
    // cannot perform enrollment operations.
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
        (access == 'r' || access == 'rw');
  }

  bool _isWriteAllowed(Verb verb, String access) {
    return (verb is Update ||
            // `update:meta` is a metadata WRITE — ttl, ttb, ccd — so it is
            // gated exactly like `update`: allowed on `rw` over the key's
            // namespace, refused otherwise. It was in neither list, and
            // `UpdateMeta` extends `Verb` rather than `Update`, so
            // checkEnrollmentNamespaceAccess returned false for every access
            // level including `*:rw` and the verb was refused to every
            // enrollment. Issue #2691.
            //
            // It went unnoticed because a connection carrying no enrollment
            // id skipped the check entirely, and that was every legacy and
            // CRAM connection — so the paths that exercise `update:meta` most
            // never reached this.
            verb is UpdateMeta ||
            verb is Delete ||
            verb is Config ||
            verb is Notify ||
            verb is NotifyAll ||
            verb is NotifyRemove ||
            verb is Monitor ||
            verb is SyncFrom) &&
        access == 'rw';
  }

  /// An atSign body, without the leading '@'. Reuses at_commons' own charset
  /// (word characters, '-', '_' and emoji; 1..55) rather than a hand-rolled
  /// `[\w\-_]{1,55}`, so emoji atSigns stay in lockstep with AtKey parsing.
  /// Contains no named groups, so it is safe to interpolate more than once.
  static const String _atSignBody = Regexes.ownershipFragmentWithoutAtPrefix;

  /// Namespace-less keys that any approved enrollment may read and write: the
  /// two encryption shared-key forms a client writes the first time it shares
  /// with another atSign.
  ///
  /// Anchored at both ends, so it matches the whole key rather than a
  /// substring of it.
  ///
  /// Neither atSign is compared against this server's own: the receiving side
  /// reads `@<me>:shared_key@<them>`, which LookupVerbHandler synthesises for
  /// an inbound `lookup:shared_key@<them>`.
  static final RegExp _rootSharedKeyRegex = RegExp(
      '^(?:@$_atSignBody:shared_key|shared_key\\.$_atSignBody)@$_atSignBody\$',
      caseSensitive: false);

  /// Namespace-less keys holding the atSign's own key material. Readable by
  /// any approved enrollment; writable only by a root enrollment
  /// ([EnrollDataStoreValue.isRootEnrollment]).
  ///
  /// Reads stay open because sync force-includes these keys
  /// (`alwaysIncludeInSync` in utils/regex_util.dart admits any namespace-less
  /// `public:` key) and then ANDs the result with this check.
  static final RegExp _ownKeyMaterialRegex = RegExp(
      '^(?:public:(?:publickey|signing_publickey)@$_atSignBody'
      '|@$_atSignBody:signing_privatekey@$_atSignBody)\$',
      caseSensitive: false);

  /// Cached copies of another atSign's public key material. Readable by any
  /// approved enrollment; writes are decided by the namespace check rather
  /// than by a root enrollment, since the data is public at its origin and the
  /// cached copy is local. DeleteVerbHandler treats cached keys the same way
  /// in exempting them from `protectedKeys`.
  static final RegExp _cachedKeyMaterialRegex = RegExp(
      '^cached:public:(?:publickey|signing_publickey)@$_atSignBody\$',
      caseSensitive: false);

  /// Namespace-less keys writable only by a root enrollment. Reads are decided
  /// by the namespace check, so sync membership is unaffected.
  ///
  /// The whole `privatekey:` prefix is covered. Its members hold the server's
  /// own credentials and internal state, and are written by the server rather
  /// than by an enrollment.
  static final RegExp _rootOnlyWritableKeyRegex = RegExp(
      '^(?:privatekey:[^\\s]+'
      '|private:blocklist@$_atSignBody'
      '|configkey)\$',
      caseSensitive: false);

  /// Whether this connection may perform atSign-level privileged operations
  /// (as opposed to key-level ones, which [isAuthorized] decides).
  ///
  /// True for a connection with no enrollment id, or for an approved root
  /// enrollment. An enrollment's namespace map is what the requesting client
  /// asked for, so approval state is part of the check.
  Future<bool> isRootPrivilegedConnection(
      InboundConnectionMetadata inboundConnectionMetadata) async {
    final enrollmentId = inboundConnectionMetadata.enrollmentId;
    if (enrollmentId == null) {
      return true;
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
  /// Not derived from [_isWriteAllowed]: Config, Monitor and SyncFrom appear in
  /// both that list and [_isReadAllowed], which would classify sync as a write.
  ///
  /// [UpdateMeta] is listed explicitly because it `extends Verb` rather than
  /// Update, so `getVerb() is Update` does not match it.
  bool isMutatingVerb() {
    final Verb verb = getVerb();
    return verb is Update ||
        verb is UpdateMeta ||
        verb is Delete ||
        verb is Notify ||
        verb is NotifyAll ||
        verb is NotifyRemove;
  }

  /// Decides a namespace-less key for an enrollment, or returns null to let
  /// the namespace check decide.
  ///
  /// [enrollmentId] is the id the connection carries. Only one key is decided
  /// by WHICH enrollment is asking rather than by what it holds — see
  /// [_isLegacyCredentialRotation].
  bool? _decideRootKey(String? atKey,
      EnrollDataStoreValue enrollDataStoreValue, String enrollmentId) {
    if (atKey == null) {
      return null;
    }
    // Matched against the form the keystore writes: HiveKeyStoreHelper
    // .prepareKey normalises with `trim().toLowerCase().replaceAll(' ', '')`.
    final String key = atKey.trim().toLowerCase().replaceAll(' ', '');

    if (_rootSharedKeyRegex.hasMatch(key)) {
      return true;
    }
    // Cached copies of another atSign's public keys: readable by any
    // enrollment; writes are decided by the namespace check.
    if (_cachedKeyMaterialRegex.hasMatch(key)) {
      return isMutatingVerb() ? null : true;
    }
    final bool isOwnKeyMaterial = _ownKeyMaterialRegex.hasMatch(key);
    if (isOwnKeyMaterial || _rootOnlyWritableKeyRegex.hasMatch(key)) {
      if (isMutatingVerb()) {
        // Root privilege alone is NOT enough for the legacy PKAM credential.
        // Every other key in this branch is decided by what the enrollment
        // holds; this one is decided by which enrollment is asking.
        if (key == AtConstants.atPkamPublicKey) {
          return _isLegacyCredentialRotation(enrollmentId);
        }
        return enrollDataStoreValue.isRootEnrollment;
      }
      // Own key material stays readable; the rest is decided below.
      return isOwnKeyMaterial ? true : null;
    }
    return null;
  }

  /// Whether a connection carrying [enrollmentId] may write
  /// `privatekey:at_pkam_publickey` — the credential LEGACY PKAM
  /// authenticates against, and the only key an enrollment can write that
  /// mints an identity rather than serving one.
  ///
  /// True only for the housekeeping enrollment, which is what a legacy
  /// connection is authenticated as. That connection proved possession of the
  /// key it is replacing by authenticating with it, so this is a credential
  /// rotating ITSELF — the same act every other enrollment performs through
  /// `enroll:update`, which cannot serve this one because the housekeeping
  /// record holds no credential to update.
  ///
  /// Every other root enrollment is refused, and that is the point. An APKAM
  /// root writing this key installs a credential IT holds as the atSign's
  /// legacy credential, and the legacy credential authenticates with no
  /// enrollment id — so revoking or expiring that root leaves the key it
  /// planted working. A compromised app root would survive its own
  /// revocation, permanently, with nothing on the roster to show for it.
  ///
  /// An owner or CRAM connection carries no enrollment id at all and never
  /// reaches here: [isAuthorized] and [isAuthorizedSync] return true for a
  /// null id before any key is examined. That is what onboarding uses to
  /// plant the first key, and it is unaffected.
  bool _isLegacyCredentialRotation(String enrollmentId) =>
      enrollmentId == EnrollmentManager.housekeepingEnrollmentId;

  /// This function checks the validity of a provided OTP.
  /// It returns true if the OTP is valid; otherwise, it returns false.
  /// If the OTP is not found in the keystore, it also returns false.
  ///
  /// Additionally, this function removes the OTP from the keystore to prevent
  /// its reuse.
  Future<bool> isPasscodeValid(String? passcode) async {
    if (passcode == null) {
      return false;
    }
    // 1. Check if user has configured an SPP(Semi-Permanent Pass-code).
    // If SPP key is available, check if the otp sent is a valid pass code.
    // If yes, return true, else check it is a valid OTP.
    String passcodeKey = OtpVerbHandler.passcodeKey(passcode, isSpp: true);
    if (!await keyStore.exists(passcodeKey)) {
      // if new SPPKey does not exist in keystore, check for SPP data against legacy SPP key
      // New SPP key has __otp namespace, legacy key does NOT have any namespace
      passcodeKey =
          'private:spp${AtSecondaryServerImpl.getInstance().currentAtSign}';
    }
    try {
      AtData? sppAtData = await keyStore.get(passcodeKey);
      // SPP has a special key so we have to check the value that was stored
      // (which is the actual SPP)
      // By comparison, OTPs are stored with the key being ${OTP}.__otp@alice
      // i.e. the OTP is part of the key, and the stored data is irrelevant
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

    // 2. If not a valid SPP, then check against OTP keys
    String otpKey = OtpVerbHandler.passcodeKey(passcode, isSpp: false);
    if (!await keyStore.exists(otpKey)) {
      // if new OTPKey does not exist in keystore, check for OTP data against legacy OTPKey
      // New OTP key has __otp namespace, legacy key does not have namespace
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
    // Remove the OTP after it is used.
    // NOTE: SPP code should NOT be deleted. only OTPs should be
    // deleted after use.
    await keyStore.remove(otpKey);

    return isOTPValid;
  }
}
