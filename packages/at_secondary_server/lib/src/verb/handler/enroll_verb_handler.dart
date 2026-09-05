import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_revocation_event.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/apkam_signature_verifier.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'abstract_verb_handler.dart';
import 'package:at_secondary/src/enroll/enrollment_access.dart';

/// Verb handler to process APKAM enroll requests
class EnrollVerbHandler extends AbstractVerbHandler {
  static Enroll enrollVerb = Enroll();

  @visibleForTesting
  static int initialDelayInMilliseconds = 1000;

  /// Delay intervals for handling a series of invalid OTPs. Initially
  /// `[0, initialDelayInMilliseconds]`, then extended Fibonacci-wise.
  @visibleForTesting
  List<int> delayForInvalidOTPSeries = <int>[0, initialDelayInMilliseconds];

  /// The maximum value for the delay interval in milliseconds.
  @visibleForTesting
  int maxDelayInMillis = Duration(
          seconds: AtSecondaryConfig.enrollmentResponseDelayIntervalInSeconds)
      .inMilliseconds;

  /// The largest enrollment record the atServer will store, measured on its
  /// JSON encoding, the string that lands in the keystore.
  static const int maxEnrollmentRecordBytes = 500 * 1024;

  final EnrollmentManager enMgr;
  final NotificationManager notifManager;

  EnrollVerbHandler(super.keyStore, this.enMgr, this.notifManager);

  @override
  bool accept(String command) => command.startsWith('enroll:');

  @override
  Verb getVerb() => enrollVerb;

  @visibleForTesting
  int enrollmentExpiryInMills =
      Duration(hours: AtSecondaryConfig.enrollmentExpiryInHours).inMilliseconds;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final responseJson = {};

    logger.finer('verb params: $verbParams');
    final operation = verbParams['operation'];
    final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    if (operation != 'request' && !atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException(
          'Cannot $operation enrollment without authentication');
    }
    EnrollParams? enrollVerbParams;

    // 'list', 'listns' and 'infons' carry no enrollParams JSON body.
    if (verbParams[AtConstants.enrollParams] == null) {
      if (operation != 'list' &&
          operation != 'listns' &&
          operation != 'infons') {
        logger.severe(
            'Enroll params is empty | EnrollParams: ${verbParams[AtConstants.enrollParams]}');
        throw IllegalArgumentException('Enroll parameters not provided');
      }
    } else {
      enrollVerbParams = EnrollParams.fromJson(
          jsonDecode(verbParams[AtConstants.enrollParams]!)
              as Map<String, dynamic>);
      // NOTE folded here, once, to EXACTLY the keystore's fold. Every id
      // comparison on the revoke path is a string comparison against this
      // value.
      enrollVerbParams.enrollmentId =
          EnrollmentManager.canonicalEnrollmentIdOrNull(
              enrollVerbParams.enrollmentId);
    }

    _validateParams(enrollVerbParams, operation!, atConnection);

    switch (operation) {
      case 'request':
        await _handleEnrollmentRequest(
          enMgr,
          enrollVerbParams!,
          currentAtSign,
          responseJson,
          atConnection,
        );
        break;

      case 'approve':
      case 'deny':
      case 'unrevoke':
        await _handleApproveDenyRevokeUnrevoke(
          enMgr,
          (atConnection.metaData as InboundConnectionMetadata),
          enrollVerbParams!,
          currentAtSign,
          operation,
          responseJson,
          response,
        );
        break;
      case 'revoke':
        var forceFlag = verbParams['force'];
        final enrollmentIdFromParams = enrollVerbParams!.enrollmentId;
        var inboundConnectionMetaData =
            atConnection.metaData as InboundConnectionMetadata;
        if (enrollmentIdFromParams == inboundConnectionMetaData.enrollmentId &&
            forceFlag == null) {
          throw AtEnrollmentRevokeException(
              'Current client cannot revoke its own enrollment');
        }
        final List<String> alsoRevoked = await _handleApproveDenyRevokeUnrevoke(
          enMgr,
          (atConnection.metaData as InboundConnectionMetadata),
          enrollVerbParams,
          currentAtSign,
          operation,
          responseJson,
          response,
        );
        if (responseJson['status'] == EnrollmentStatus.revoked.name) {
          logger.info(
              'Dropping any open connections for enrollmentId: $enrollmentIdFromParams');
          // The whole INTENDED set, cascade included, rather than the subset
          // this call flipped.
          await _dropRevokedClientConnections(
              {enrollmentIdFromParams!, ...alsoRevoked},
              forceFlag != null,
              atConnection,
              responseJson);
        }
        break;
      case 'list':
        response.data = await _fetchEnrollmentRequests(
          enMgr,
          atConnection,
          currentAtSign,
          enrollVerbParams: enrollVerbParams,
        );
        return;
      case 'listns':
        response.data = await _fetchEnrollmentsForNamespace(
          enMgr,
          atConnection,
          verbParams['listNamespace'] ?? '',
        );
        return;
      case 'infons':
        response.data = await _fetchNamespaceInfo(
          enMgr,
          atConnection,
          verbParams['listNamespace'] ?? '',
        );
        return;
      case 'fetch':
        response.data = await _fetchEnrollmentInfoById(
          enMgr,
          enrollVerbParams,
          currentAtSign,
          response,
          atConnection,
        );
        return;
      case 'delete':
        await _deleteEnrollment(
          enMgr,
          enrollVerbParams,
          currentAtSign,
          responseJson,
          response,
          atConnection,
        );
        break;
      case 'update':
        await _handleEnrollmentUpdate(
          enMgr,
          (atConnection.metaData as InboundConnectionMetadata),
          enrollVerbParams!,
          currentAtSign,
          responseJson,
          response,
        );
        break;
    }
    response.data = jsonEncode(responseJson);
    return;
  }

  /// Fetches the enrollment request with enrollment id.
  Future<String> _fetchEnrollmentInfoById(
    EnrollmentManager enMgr,
    EnrollParams? enrollVerbParams,
    currentAtSign,
    Response response,
    InboundConnection atConnection,
  ) async {
    // _validateParams has already refused a null enrollmentId.
    final String targetEnrollmentId = enrollVerbParams!.enrollmentId!;
    EnrollDataStoreValue enrollDataStoreValue =
        await enMgr.getEnrollmentById(targetEnrollmentId);

    // A caller may always fetch its OWN enrollment, and a connection carrying
    // no enrollment id may fetch any. Fetching ANOTHER enrollment requires
    // __manage AND access to EVERY namespace the target holds.
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final callerEnrollmentId = inboundConnectionMetadata.enrollmentId;
    if (!AbstractVerbHandler.isCramConnection(inboundConnectionMetadata) &&
        callerEnrollmentId != targetEnrollmentId) {
      if (enrollDataStoreValue.namespaces.isEmpty) {
        throw UnAuthorizedException(
            'Not authorized to fetch enrollment $targetEnrollmentId: it holds'
            ' no namespaces, so no caller can demonstrate authority over it.'
            ' Fetch it from the enrollment itself, or from a CRAM'
            ' connection');
      }
      for (final MapEntry<String, String> entry
          in enrollDataStoreValue.namespaces.entries) {
        final bool isAuthorised = await isAuthorized(inboundConnectionMetadata,
            namespace: entry.key,
            enrolledNamespaceAccess: entry.value,
            operation: 'fetch');
        if (!isAuthorised) {
          throw UnAuthorizedException(
              'Not authorized to fetch enrollment $targetEnrollmentId:'
              ' requires __manage and access to all of its namespaces');
        }
      }
    }

    // `expiresAt` is the effective expiry, read from the record's metadata.
    return jsonEncode({
      'appName': enrollDataStoreValue.appName,
      'deviceName': enrollDataStoreValue.deviceName,
      'namespace': enrollDataStoreValue.namespaces,
      'encryptedAPKAMSymmetricKey':
          enrollDataStoreValue.encryptedAPKAMSymmetricKey,
      'status': enrollDataStoreValue.approval?.state,
      'expiresAt': EnrollmentManager.expiresAtField(
          await enMgr.effectiveExpiryOf(
              enMgr.buildEnrollmentKey(targetEnrollmentId))),
    });
  }

  /// `enroll:request`. Mints an enrollment record, excluded from the commit
  /// log so enrollment keys never sync to clients.
  ///
  /// Throws [IllegalArgumentException] on an invalid OTP, and
  /// [AtThrottleLimitExceeded] when requests exceed the rate limit.
  Future<void> _handleEnrollmentRequest(
      EnrollmentManager enMgr,
      EnrollParams enrollParams,
      currentAtSign,
      Map<dynamic, dynamic> responseJson,
      InboundConnection atConnection) async {
    if (!atConnection.isRequestAllowed()) {
      throw AtThrottleLimitExceeded(
          'Enrollment requests have exceeded the limit within the specified time frame');
    }

    // Structural checks plus a size pre-filter, before an OTP is spent.
    _validateEnrollParams(enrollParams);

    if (atConnection.metaData.isAuthenticated == false) {
      var isValid = await isPasscodeValid(enrollParams.otp);
      if (!isValid) {
        await Future.delayed(
            Duration(milliseconds: getDelayIntervalInMilliseconds()));
        throw IllegalArgumentException(
            'invalid otp. Cannot process enroll request');
      } else {
        delayForInvalidOTPSeries.clear();
        delayForInvalidOTPSeries.addAll([0, initialDelayInMilliseconds]);
      }
    }

    // NOTE the throttle and OTP gate stay OUTSIDE the section: the
    // invalid-OTP arm sleeps for a growing interval, and would hold the
    // atSign's one enrollment-mutation lock while it did.
    return enMgr.serialiseMutation(() => _enrollmentRequestUnderLock(
        enMgr, enrollParams, currentAtSign, responseJson, atConnection));
  }

  /// The read-decide-write half of [_handleEnrollmentRequest], run under
  /// [EnrollmentManager.serialiseMutation].
  Future<void> _enrollmentRequestUnderLock(
      EnrollmentManager enMgr,
      EnrollParams enrollParams,
      currentAtSign,
      Map<dynamic, dynamic> responseJson,
      InboundConnection atConnection) async {
    var enrollNamespaces = enrollParams.namespaces ?? {};
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;

    if (AbstractVerbHandler.isCramConnection(atConnection.metaData as InboundConnectionMetadata)) {
      logger.warning('CRAM-authenticated connection - i.e. initial enrollment;'
          ' will replace the existing initial enrollment, if any');
    } else if (carriesEnrollment(inboundConnectionMetadata)) {
      // A self-enrollment keeps its app's own (appName, deviceName).
    } else {
      await preventDuplicateEnrollRequest(enrollParams);
    }
    // AFTER the (appName, deviceName) rule, and before anything is written.
    await _refuseKeyHeldByAnotherEnrollment(
        enrollParams.apkamPublicKey!, enrollParams.signingAlgo);

    var newEnrollmentId = Uuid().v4();
    var enrollmentKey = enMgr.buildEnrollmentKey(newEnrollmentId);
    logger.finer('New enrollment key created : $enrollmentKey$currentAtSign');

    responseJson['enrollmentId'] = newEnrollmentId;
    final enrollmentValue = EnrollDataStoreValue(
        atConnection.metaData.sessionID!,
        enrollParams.appName!,
        enrollParams.deviceName!,
        enrollParams.apkamPublicKey!);
    enrollmentValue.namespaces = enrollNamespaces;
    enrollmentValue.requestType = EnrollRequestType.newEnrollment;

    // Persisted verbatim from EnrollParams; no separate metadata write.
    if (enrollParams.metadata != null) {
      enrollmentValue.metadata = enrollParams.metadata;
    }
    if (enrollParams.signingAlgo != null) {
      enrollmentValue.signingAlgo = enrollParams.signingAlgo;
    }
    // At most one of the two is set: _validateEnrollParams refused both.
    if (enrollParams.apsk != null) {
      enrollmentValue.apsk = enrollParams.apsk;
    }
    if (enrollParams.apskLegacy != null) {
      enrollmentValue.apskLegacy = enrollParams.apskLegacy;
    }

    if (enrollParams.apkamKeysExpiryDuration != null) {
      enrollmentValue.apkamKeysExpiryDuration =
          enrollParams.apkamKeysExpiryDuration!;
    }

    if (AbstractVerbHandler.isCramConnection(atConnection.metaData as InboundConnectionMetadata)) {
      enrollNamespaces[EnrollmentConstants.enrollManageNamespace] = 'rw';
      enrollNamespaces[EnrollmentConstants.allNamespaces] = 'rw';
      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      responseJson['status'] = 'approved';
      final inboundConnectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      inboundConnectionMetadata.enrollmentId = newEnrollmentId;
      // Before any write, so a refusal leaves no published _apsk behind.
      _validateRecordSize(enrollmentValue);

      // ⛔ This branch must NOT copy the APKAM public key into
      // `at_pkam_publickey`: that gives one keypair two identities with
      // separate lifecycles, and the write is unconditional.

      await _publishApskSigningKey(
          newEnrollmentId, enrollmentValue, currentAtSign);
      AtData enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());

      await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.approved);
      return;
    }

    // A connection already holding an enrollment retrofits itself: a FRESH
    // enrollment that REPLACES the one it authenticated as, auto-approved
    // with no OTP, holding exactly the predecessor's grants.
    //
    // ⚠️ Keyed on the enrollment the connection carries rather than on the
    // auth type, and placed AFTER the CRAM auto-approve.
    if (carriesEnrollment(inboundConnectionMetadata)) {
      final String predecessorId = inboundConnectionMetadata.enrollmentId!;
      final EnrollDataStoreValue predecessor;
      try {
        predecessor = await enMgr.getEnrollmentById(predecessorId);
      } on KeyNotFoundException {
        throw UnAuthorizedException(
            'Predecessor enrollment $predecessorId does not exist or has '
            'expired');
      }
      if (predecessor.approval?.state != EnrollmentStatus.approved.name) {
        throw UnAuthorizedException(
            'Predecessor enrollment $predecessorId is not approved');
      }
      if (predecessor.namespaces.isEmpty) {
        throw UnAuthorizedException(
            'Predecessor enrollment $predecessorId holds no namespaces, and a '
            'replacement carries exactly the grants of the enrollment it '
            'replaces, so it would hold none either');
      }
      // A retrofit is a ONCE-OFF: one no-approver migration per device.
      if (predecessor.retrofitPredecessorEnrollmentId != null) {
        throw UnAuthorizedException(
            'Enrollment $predecessorId is itself a replacement, and a '
            'replacement may not be replaced without an approver');
      }
      if (!predecessor.isRootEnrollment &&
          await _retrofitCapAlreadyArmed(enMgr, predecessorId)) {
        throw UnAuthorizedException(
            'Enrollment $predecessorId has already been replaced, and its '
            'replacement has authenticated; a second split is not allowed '
            'once the first successor has authenticated. A sibling clone of '
            'this keyfile enrols over an OTP');
      }
      // Escalation first, so a request naming MORE keeps its own diagnosis.
      verifyNoEscalation(predecessor.namespaces, enrollNamespaces);
      requireGrantsMatchPredecessor(predecessor.namespaces, enrollParams.namespaces);
      enrollmentValue.namespaces = Map.of(predecessor.namespaces);

      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      // What this successor REPLACED, which the retrofit cap reads.
      // ⛔ Not for revocation: the revoke path does NOT walk this edge.
      enrollmentValue.retrofitPredecessorEnrollmentId = predecessorId;
      // A retrofit takes the predecessor's place in the approval graph.
      enrollmentValue.parentEnrollmentId =
          predecessor.parentEnrollmentId;
      if (enrollParams.apkamKeysExpiryDuration == null) {
        enrollmentValue.apkamKeysExpiryDuration =
            predecessor.apkamKeysExpiryDuration;
      }
      // NOTE a stated posture may narrow the predecessor's, never widen it;
      // zero and negative both ask for a permanent credential.
      final predecessorExpiryMs = predecessor.apkamKeysExpiryDuration.inMilliseconds;
      final statedExpiryMs =
          enrollmentValue.apkamKeysExpiryDuration.inMilliseconds;
      if (statedExpiryMs < 0 ||
          (predecessorExpiryMs > 0 &&
              (statedExpiryMs <= 0 || statedExpiryMs > predecessorExpiryMs))) {
        logger.warning(
            'Self-enrollment under $predecessorId asked for a key-expiry '
            'of ${statedExpiryMs}ms against a predecessor bound to '
            '${predecessorExpiryMs}ms; using the predecessor\'s');
        enrollmentValue.apkamKeysExpiryDuration =
            predecessor.apkamKeysExpiryDuration;
      }

      // The clamp above compares TERMS, and a capped predecessor's real
      // deadline lives only in its RECORD metadata, so bound the successor by
      // that stored DEADLINE. The POSTURE is narrowed rather than the ttl.
      DateTime? boundedDeadline;
      final DateTime? predecessorExpiresAt =
          (await keyStore.getMeta(enMgr.buildEnrollmentKey(predecessorId)))
              ?.expiresAt
              ?.toUtc();
      if (predecessorExpiresAt != null) {
        final int remainingMs = predecessorExpiresAt
            .difference(DateTime.now().toUtc())
            .inMilliseconds;
        // Zero is the keystore's "never expires".
        final int boundedMs = remainingMs < 1 ? 1 : remainingMs;
        final int statedMs =
            enrollmentValue.apkamKeysExpiryDuration.inMilliseconds;
        if (statedMs <= 0 || statedMs > boundedMs) {
          logger.warning(
              'Self-enrollment under $predecessorId asked for ${statedMs}ms '
              'against a predecessor whose record expires at '
              '$predecessorExpiresAt; bounding it to ${boundedMs}ms');
          enrollmentValue.apkamKeysExpiryDuration =
              Duration(milliseconds: boundedMs);
          // Carried as an ABSOLUTE: a ttl is re-anchored at the write.
          boundedDeadline = predecessorExpiresAt;
        }
      }
      // May be absent: a PQ self-enrollment conveys legacy material
      // client-side.
      enrollmentValue.encryptedAPKAMSymmetricKey =
          enrollParams.encryptedAPKAMSymmetricKey;
      responseJson['status'] = 'approved';

      // Before any write, so a refusal leaves no published _apsk behind.
      _validateRecordSize(enrollmentValue);
      await _publishApskSigningKey(
          newEnrollmentId, enrollmentValue, currentAtSign);
      // A ttl of zero is the keystore's "never expires".
      await enMgr.put(
          newEnrollmentId,
          AtData()
            ..data = jsonEncode(enrollmentValue.toJson())
            ..metaData = (AtMetaData()
              ..ttl = enrollmentValue.apkamKeysExpiryDuration.inMilliseconds),
          EnrollmentStatus.approved,
          assertedTimestamps: boundedDeadline == null
              ? null
              : AtAssertedTimestamps(expiresAt: boundedDeadline));

      // NOTE the predecessor is NOT capped here; the cap is armed by the
      // successor's FIRST PKAM authentication.
      return;
    }

    // A standard request: notify an approver app, and store it `pending`.
    enrollmentValue.encryptedAPKAMSymmetricKey =
        enrollParams.encryptedAPKAMSymmetricKey;
    enrollmentValue.approval = EnrollApproval(EnrollmentStatus.pending.name);
    responseJson['status'] = 'pending';
    // Every check runs before the notification.
    _validateRecordSize(enrollmentValue);
    await _storeNotification(enrollmentKey, enrollParams, currentAtSign);
    AtData enrollData = AtData()
      ..data = jsonEncode(enrollmentValue.toJson())
      // A pending enrollment expires after the configured limit.
      ..metaData = (AtMetaData()..ttl = enrollmentExpiryInMills);

    await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.pending);
  }

  /// Rejects any requested grant the predecessor enrollment does not hold.
  ///
  /// `__manage` and `*` must be held literally; a predecessor's `*` covers
  /// any other namespace at the letters it carries.
  @visibleForTesting
  void verifyNoEscalation(
      Map<String, String> predecessorGrants, Map<String, String> requested) {
    for (final entry in requested.entries) {
      String? predecessorAccess = predecessorGrants[entry.key];
      final isSpecial = entry.key == EnrollmentConstants.allNamespaces ||
          entry.key == EnrollmentConstants.enrollManageNamespace;
      if (predecessorAccess == null && !isSpecial) {
        predecessorAccess = predecessorGrants[EnrollmentConstants.allNamespaces];
      }
      final held = predecessorAccess;
      if (held == null ||
          !entry.value.split('').every(held.split('').contains)) {
        throw UnAuthorizedException(
            'Requested namespace "${entry.key}:${entry.value}" exceeds the '
            'predecessor enrollment\'s grants — a retrofit carries exactly '
            'what the enrollment it replaces holds');
      }
    }
  }

  /// Refuses a self-enrollment whose stated grants are not exactly those of
  /// the enrollment it replaces.
  ///
  /// [requested] is optional: omit it and the predecessor's grants are
  /// inherited, state it and it must name exactly them.
  @visibleForTesting
  void requireGrantsMatchPredecessor(
      Map<String, String> predecessorGrants, Map<String, String>? requested) {
    if (requested == null || requested.isEmpty) return;
    if (requested.length == predecessorGrants.length &&
        requested.entries.every((e) => predecessorGrants[e.key] == e.value)) {
      return;
    }
    throw UnAuthorizedException(
        'a self-enrollment replaces its predecessor and carries its grants: '
        'requested $requested, but the enrollment being replaced holds '
        '$predecessorGrants. Omit "namespaces" to inherit them, or state '
        'exactly them.');
  }

  /// Handles `enroll:approve`, `deny`, `revoke` and `unrevoke`, updating the
  /// stored enrollment's status and, on approve, storing the encrypted
  /// encryption keys.
  ///
  /// Returns every id the revoke INTENDED to revoke by cascade, empty for
  /// every other operation.
  Future<List<String>> _handleApproveDenyRevokeUnrevoke(
      EnrollmentManager enMgr,
      InboundConnectionMetadata inboundConnectionMetadata,
      EnrollParams enrollParams,
      currentAtSign,
      String operation,
      Map<dynamic, dynamic> responseJson,
      Response response) async {
    // NOTE the SPAN is the point rather than the write: a revoke reads the
    // target, walks its descendants and asks whether an unexpiring root
    // survives the act, all before writing.
    return enMgr.serialiseMutation(() => _approveDenyRevokeUnrevokeUnderLock(
        enMgr,
        inboundConnectionMetadata,
        enrollParams,
        currentAtSign,
        operation,
        responseJson,
        response));
  }

  /// The read-decide-write half of [_handleApproveDenyRevokeUnrevoke], run
  /// under [EnrollmentManager.serialiseMutation].
  Future<List<String>> _approveDenyRevokeUnrevokeUnderLock(
      EnrollmentManager enMgr,
      InboundConnectionMetadata inboundConnectionMetadata,
      EnrollParams enrollParams,
      currentAtSign,
      String operation,
      Map<dynamic, dynamic> responseJson,
      Response response) async {
    final String enId = enrollParams.enrollmentId!;

    EnrollDataStoreValue? enVal;
    EnrollmentStatus? status;
    try {
      enVal = await enMgr.getEnrollmentById(enId);
    } on KeyNotFoundException {
      status = EnrollmentStatus.expired;
    }
    status ??= EnrollmentStatus.values.byName(enVal!.approval!.state);
    if (EnrollmentStatus.expired == status) {
      response.isError = true;
      response.errorCode = 'AT0028';
      response.errorMessage = 'enrollment_id: $enId is expired or invalid';
      return const [];
    }

    try {
      _verifyEnrollmentStateBeforeAction(operation, status);
    } on IllegalStateException catch (e) {
      throw IllegalStateException(
          'Failed to $operation enrollment id: $enId. ${e.message}');
    }
    if (operation == 'approve' && enVal!.namespaces.isEmpty) {
      throw IllegalArgumentException(
          'Failed to approve enrollment id: $enId. It holds no namespaces, '
          'and an approved enrollment granting nothing must not exist');
    }

    // NOTE a target holding NO namespaces passes the loop below vacuously,
    // so it is refused here; the self and CRAM clauses stay open.
    final String? callerIdForAuthz = inboundConnectionMetadata.enrollmentId;
    if (!AbstractVerbHandler.isCramConnection(inboundConnectionMetadata) &&
        callerIdForAuthz != enId &&
        enVal!.namespaces.isEmpty) {
      throw UnAuthorizedException('Failed to $operation enrollment id: $enId.'
          ' It holds no namespaces, so no caller can demonstrate authority'
          ' over it. Act on it from the enrollment itself, or from a CRAM'
          ' connection');
    }

    for (MapEntry<String, String> entry in enVal!.namespaces.entries) {
      bool isAuthorised = await isAuthorized(inboundConnectionMetadata,
          namespace: entry.key,
          enrolledNamespaceAccess: entry.value,
          operation: operation);

      if (isAuthorised == false) {
        throw UnAuthorizedException('Failed to $operation enrollment id: $enId.'
            ' Client is not authorized for namespaces in the enrollment request');
      }
    }

    // Everything below is decided BEFORE anything is written.
    List<String> cascadeIds = const [];
    final String? callerId = inboundConnectionMetadata.enrollmentId;
    if (operation == 'revoke') {
      cascadeIds = (await enMgr.descendantsOf(enId)).toList();

      // A revoker must survive its own act.
      if (callerId != null && cascadeIds.contains(callerId)) {
        throw AtEnrollmentRevokeException(
            'Cannot revoke enrollment $enId: $callerId, the enrollment making '
            'this request, descends from it by approval and would be revoked '
            'by the same cascade. Revoke $enId from an enrollment outside the '
            'chain of approvals beneath it');
      }

      // Revoking a fully privileged enrollment may not leave the atSign
      // without a PERMANENT one. Asked of the ACT rather than of the target,
      // over what SURVIVES the cascade, and skipped for a connection carrying
      // no enrollment id.
      if (callerId != null) {
        // Cheapest question first: the liveness question walks the keystore.
        final List<String> rootsRemoved = [
          if (await enMgr.isUsableRootEnrollment(enId, enVal)) enId,
          ...await enMgr.approvedRootEnrollmentsAmong(cascadeIds),
        ];
        if (rootsRemoved.isNotEmpty &&
            !await enMgr.hasUnexpiringRootEnrollment({enId, ...cascadeIds})) {
          throw AtEnrollmentRevokeException(
              'Cannot revoke enrollment $enId: it would remove the fully '
              'privileged enrollment(s) ${rootsRemoved.join(', ')} and no '
              'fully privileged enrollment surviving it on $currentAtSign is '
              'permanent, so the atSign would be left unable to approve a '
              'replacement once the remaining ones expire. Approve another '
              'fully privileged enrollment that does not expire first');
        }
      }
    } else if (operation == 'approve' || operation == 'unrevoke') {
      await _refuseIfApproverNotApproved(enMgr, enId, enVal, operation);
    }

    // The cascade goes FIRST, before the target's own write, so a part-way
    // failure is finished by re-running. One moment for the whole command.
    final DateTime commandAt = DateTime.now().toUtc();
    final List<String> cascaded = cascadeIds.isEmpty
        ? const []
        : await enMgr.revokeAll(cascadeIds,
            byEnrollmentId: callerId, cascadedFrom: enId, at: commandAt);
    if (cascaded.isNotEmpty) {
      logger.info(
          'Revoking $enId cascaded to ${cascaded.length} enrollment(s) that '
          'descend from it: ${cascaded.join(', ')}');
    }

    EnrollmentStatus newEnrollmentStatus = _getEnrollStatusEnum(operation);
    enVal.approval!.state = newEnrollmentStatus.name;
    responseJson['status'] = newEnrollmentStatus.name;

    // The revocation history for the enrollment this command NAMED. Grants
    // are read off the record BEFORE the write, and recorded on the un-revoke
    // too.
    EnrollmentRevocationEvent? revocationEvent;
    if (operation == 'revoke' || operation == 'unrevoke') {
      revocationEvent = EnrollmentRevocationEvent(
        type: operation == 'revoke'
            ? EnrollmentRevocationEventType.revoked
            : EnrollmentRevocationEventType.unrevoked,
        enrollmentId: enId,
        at: commandAt,
        namespaces: Map<String, String>.from(enVal.namespaces),
        byEnrollmentId: callerId,
        cascadedFrom: null,
      );
    }
    // A revoke records BEFORE its write and an un-revoke AFTER it.
    if (operation == 'revoke') {
      await enMgr.recordRevocationEvents([revocationEvent!]);
    }

    // Read off the connection rather than the request, so an approver cannot
    // name someone else as the admitting party.
    if (operation == 'approve') {
      final String? approverId = inboundConnectionMetadata.enrollmentId;
      enVal.parentEnrollmentId =
          (approverId != null && approverId.isNotEmpty) ? approverId : null;
    }

    AtData atData = AtData()..data = jsonEncode(enVal.toJson());
    // Approval resets the ttl off the enrollment's APKAM key-expiry posture.
    // NOTE a non-positive posture is written as 0, never passed through: a
    // negative ttl leaves the pending record's expiry standing.
    if (operation == 'approve') {
      String ek = enMgr.buildEnrollmentKey(enId);
      AtMetaData emd = await keyStore.getMeta(ek) ?? AtMetaData();
      final int postureMs = enVal.apkamKeysExpiryDuration.inMilliseconds;
      emd.ttl = postureMs > 0 ? postureMs : 0;
      atData.metaData = emd;
    }
    // NOTE a write that says nothing about expiry must not MOVE expiry, so
    // the stored absolute is asserted back. `approve` is the exception above.
    AtAssertedTimestamps? expiryCarry;
    if (operation != 'approve') {
      final AtMetaData? stored =
          await keyStore.getMeta(enMgr.buildEnrollmentKey(enId));
      if (stored?.expiresAt != null) {
        expiryCarry = AtAssertedTimestamps(expiresAt: stored!.expiresAt);
      }
    }

    await enMgr.put(enId, atData, newEnrollmentStatus,
        assertedTimestamps: expiryCarry);

    if (operation == 'unrevoke') {
      await enMgr.recordRevocationEvents([revocationEvent!]);
    }

    if (operation == 'approve') {
      await _storeEncryptionKeys(enId, enrollParams, enVal);
      // Read off the RECORD, not off these approve params.
      await _publishApskSigningKey(enId, enVal, currentAtSign);
    }
    responseJson['enrollmentId'] = enId;
    // Emitted only when a cascade happened.
    if (cascaded.isNotEmpty) {
      responseJson['cascadedEnrollmentIds'] = cascaded;
    }
    return cascadeIds;
  }

  /// Refuses an operation that would make [enId] active while the enrollment
  /// that APPROVED it is not.
  ///
  /// Allowed when nothing recorded here admitted [enId], and when the
  /// approver no longer exists.
  Future<void> _refuseIfApproverNotApproved(EnrollmentManager enMgr,
      String enId, EnrollDataStoreValue enVal, String operation) async {
    final String? approverId = enVal.parentEnrollmentId;
    if (approverId == null) return;
    final EnrollDataStoreValue approver;
    try {
      approver = await enMgr.getEnrollmentById(approverId);
    } on KeyNotFoundException {
      return;
    }
    final String? state = approver.approval?.state;
    if (state == EnrollmentStatus.approved.name) return;
    throw IllegalStateException(
        'Cannot $operation enrollment $enId: the enrollment that approved it '
        '($approverId) is $state, and reactivating $enId would restore the '
        'access that was withdrawn from $approverId');
  }

  /// `enroll:update`: an approved enrollment amending its OWN record.
  ///
  /// Reaches `apkamPublicKey`, `signingAlgo`, `apsk` and `metadata`, and
  /// nothing else: `namespaces` and the approval state are permanently out of
  /// reach. Metadata is a per-key set, never a whole-map replace.
  Future<void> _handleEnrollmentUpdate(
    EnrollmentManager enMgr,
    InboundConnectionMetadata connectionMetadata,
    EnrollParams enrollParams,
    String currentAtSign,
    Map<dynamic, dynamic> responseJson,
    Response response,
  ) async {
    final enId = enrollParams.enrollmentId!;

    // NOTE self-only, and an explicit exception to `isAuthorized`'s "no
    // enrollmentId means full permissions" default.
    if (connectionMetadata.enrollmentId != enId) {
      throw AtEnrollmentException(
          'enroll:update is self-only: this connection is authenticated as '
          '${connectionMetadata.enrollmentId ?? "the owner"}, not $enId. '
          'Authenticate as $enId to update it');
    }

    // Everything below reads the record, decides against it and writes it.
    return enMgr.serialiseMutation(() => _enrollmentUpdateUnderLock(
        enMgr, enrollParams, currentAtSign, responseJson));
  }

  /// The read-decide-write half of [_handleEnrollmentUpdate], run under
  /// [EnrollmentManager.serialiseMutation].
  Future<void> _enrollmentUpdateUnderLock(
    EnrollmentManager enMgr,
    EnrollParams enrollParams,
    String currentAtSign,
    Map<dynamic, dynamic> responseJson,
  ) async {
    final enId = enrollParams.enrollmentId!;

    final enVal = await enMgr.getEnrollmentById(enId);
    final status = EnrollmentStatus.values.byName(enVal.approval!.state);
    if (status != EnrollmentStatus.approved) {
      throw AtEnrollmentException(
          'enroll:update requires an approved enrollment; $enId is '
          '${status.name}');
    }

    _validateEnrollParams(enrollParams);

    if (enrollParams.apkamPublicKey != null) {
      final newSigningAlgo = enrollParams.signingAlgo ?? enVal.signingAlgo;
      await _verifyApkamPublicKeyPossession(
        enrollmentId: enId,
        apkamPublicKey: enrollParams.apkamPublicKey!,
        signingAlgo: newSigningAlgo,
        signature: enrollParams.apkamPublicKeySignature,
      );
      // The record re-sending its own current key is not a collision.
      await _refuseKeyHeldByAnotherEnrollment(
          enrollParams.apkamPublicKey!, newSigningAlgo,
          excluding: enId);
      enVal.apkamPublicKey = enrollParams.apkamPublicKey!;
      if (enrollParams.signingAlgo != null) {
        enVal.signingAlgo = enrollParams.signingAlgo;
      }
    } else if (enrollParams.signingAlgo != null) {
      // The algorithm describes the key, and PKAM verification is
      // record-authoritative.
      throw IllegalArgumentException(
          'signingAlgo cannot be changed without apkamPublicKey: the '
          'algorithm describes the key');
    }

    // Setting either shape clears the other: one record, one value.
    if (enrollParams.apsk != null) {
      enVal.apsk = enrollParams.apsk;
      enVal.apskLegacy = null;
    } else if (enrollParams.apskLegacy != null) {
      enVal.apskLegacy = enrollParams.apskLegacy;
      enVal.apsk = null;
    }

    if (enrollParams.metadata != null) {
      final merged = Map<String, dynamic>.from(enVal.metadata ?? {});
      merged.addAll(enrollParams.metadata!);
      enVal.metadata = merged;
    }

    // Measured AFTER the merge: metadata merges rather than replaces.
    _validateRecordSize(enVal);

    // NOTE the stored expiry is asserted back below, or an enrollment could
    // postpone its own retirement by amending itself. The status is read off
    // the record JUST BEFORE the write, never off the snapshot above, and a
    // record no longer approved is REFUSED rather than written.
    final AtData? fresh;
    try {
      fresh = await keyStore.get(enMgr.buildEnrollmentKey(enId));
    } on KeyNotFoundException {
      throw AtEnrollmentException(
          'enroll:update: enrollment $enId no longer exists');
    }
    final String? freshRaw = fresh?.data;
    EnrollmentStatus? current;
    if (freshRaw != null) {
      try {
        current = EnrollmentStatus.values.asNameMap()[
            EnrollDataStoreValue.fromJson(jsonDecode(freshRaw)).approval?.state ??
                ''];
      } on FormatException {
        current = null;
      }
    }
    if (current == null) {
      throw AtEnrollmentException(
          'enroll:update: enrollment $enId does not decode as of this write');
    }
    if (current != EnrollmentStatus.approved) {
      throw AtEnrollmentException(
          'enroll:update: enrollment $enId is ${current.name} as of this'
          ' write, though it was approved when the request was checked');
    }
    final AtMetaData? storedMeta = fresh!.metaData;
    await enMgr.put(enId, AtData()..data = jsonEncode(enVal), current,
        assertedTimestamps: storedMeta?.expiresAt == null
            ? null
            : AtAssertedTimestamps(expiresAt: storedMeta!.expiresAt));

    // Republish only when the request carried a new value.
    if (enrollParams.apsk != null || enrollParams.apskLegacy != null) {
      await _publishApskSigningKey(enId, enVal, currentAtSign);
    }

    responseJson['enrollmentId'] = enId;
    // The status just read off the record, not a constant.
    responseJson['status'] = current.name;
  }

  /// Verifies that whoever sent this `enroll:update` holds the private half of
  /// the [apkamPublicKey] it is asking to install.
  ///
  /// The signature covers `<enrollmentId>|<apkamPublicKey>|<signingAlgo>` and
  /// is verified against the new public key carried in the same request.
  Future<void> _verifyApkamPublicKeyPossession({
    required String enrollmentId,
    required String apkamPublicKey,
    required String? signingAlgo,
    required String? signature,
  }) async {
    if (signature == null || signature.isEmpty) {
      throw AtEnrollmentException(
          'enroll:update changing apkamPublicKey requires '
          'apkamPublicKeySignature: proof the sender holds the private half '
          'of the key it is installing');
    }

    // NOTE the framing must match `pkam:` byte-for-byte: a key installed
    // here has to be able to authenticate afterwards.
    final signable = '$enrollmentId|$apkamPublicKey|$signingAlgo';
    final verified = await ApkamSignatureVerifier.verify(
      message: utf8.encode(signable),
      base64Signature: signature,
      publicKey: apkamPublicKey,
      signingAlgo: ApkamSignatureVerifier.signingAlgoTypeOf(signingAlgo),
    );
    if (!verified) {
      throw AtEnrollmentException(
          'apkamPublicKeySignature does not verify against the '
          'apkamPublicKey being installed');
    }
  }

  Future<void> _dropRevokedClientConnections(
      Set<String> enrollmentIds,
      bool forceFlag,
      InboundConnection currentInboundConnection,
      responseJson) async {
    final inboundPool =
        AtSecondaryServerImpl.getInstance().inboundConnectionManager.pool;
    List<InboundConnection> connectionsToRemove = [];
    for (InboundConnection connection in inboundPool.getConnections()) {
      var inboundConnectionMetadata =
          connection.metaData as InboundConnectionMetadata;
      if (!connection.isInValid() &&
          enrollmentIds.contains(inboundConnectionMetadata.enrollmentId)) {
        logger.finer(
            'Removing APKAM revoked client connection: ${connection.metaData.sessionID}');
        connectionsToRemove.add(connection);
      }
    }
    for (InboundConnection inboundConnection in connectionsToRemove) {
      if (forceFlag &&
          inboundConnection.metaData.sessionID ==
              currentInboundConnection.metaData.sessionID) {
        logger.finer(
            'Closing current inbound connection due to enroll:revoke:force');
        responseJson['message'] =
            'Enrollment is revoked. Closing the connection in 10 seconds';
        Future.delayed(Duration(seconds: 10), () async {
          logger.finer('Closing revoked self inbound connection');
          connectionsToRemove.remove(inboundConnection);
          await inboundConnection.close();
        });
      } else {
        inboundPool.remove(inboundConnection);
        await inboundConnection.close();
      }
    }
  }

  /// Stores the encrypted default encryption private key and the encrypted
  /// self encryption key against the enrollment's `__manage` keys, which an
  /// approving app reads to convey the keys to a new enrolling app.
  Future<void> _storeEncryptionKeys(
    String newEnrollmentId,
    EnrollParams enrollParams,
    EnrollDataStoreValue enVal,
  ) async {
    AtMetaData atMetaData = AtMetaData();
    atMetaData.ttl = enVal.apkamKeysExpiryDuration.inMilliseconds;

    var privateKeyJson = {};
    privateKeyJson['value'] = enrollParams.encryptedDefaultEncryptionPrivateKey;
    if (enrollParams.encPrivateKeyIV != null) {
      privateKeyJson['iv'] = enrollParams.encPrivateKeyIV;
    }
    await keyStore.put(
        enMgr.keyForPEK(newEnrollmentId),
        AtData()
          ..data = jsonEncode(privateKeyJson)
          ..metaData = atMetaData,
        skipCommit: true);

    var selfKeyJson = {};
    selfKeyJson['value'] = enrollParams.encryptedDefaultSelfEncryptionKey;
    if (enrollParams.selfEncKeyIV != null) {
      selfKeyJson['iv'] = enrollParams.selfEncKeyIV;
    }
    await keyStore.put(
        enMgr.keyForSEK(newEnrollmentId),
        AtData()
          ..data = jsonEncode(selfKeyJson)
          ..metaData = atMetaData,
        skipCommit: true);
  }

  /// Refuses a request carrying both `_apsk` shapes, and refuses one whose
  /// payload cannot fit in an enrollment record.
  ///
  /// The size check here is a pre-filter, run before the OTP is spent;
  /// [_validateRecordSize] holds the bound.
  void _validateEnrollParams(EnrollParams enrollParams) {
    if (enrollParams.apsk != null && enrollParams.apskLegacy != null) {
      throw IllegalArgumentException(
          'apsk and apskLegacy are mutually exclusive: one enrollment '
          'publishes one _apsk value');
    }

    final length = utf8.encode(jsonEncode(enrollParams.toJson())).length;
    if (length > maxEnrollmentRecordBytes) {
      throw IllegalArgumentException(
          'enroll params are $length bytes encoded, which exceeds the '
          '$maxEnrollmentRecordBytes byte enrollment record limit');
    }
  }

  /// Refuses an enrollment record over [maxEnrollmentRecordBytes], measured on
  /// the JSON that would land in the keystore.
  ///
  /// Called before every write, on the record as it will be stored and so
  /// after any merge.
  void _validateRecordSize(EnrollDataStoreValue enVal) {
    final length = utf8.encode(jsonEncode(enVal.toJson())).length;
    if (length > maxEnrollmentRecordBytes) {
      throw IllegalArgumentException(
          'enrollment record is $length bytes encoded, which exceeds the '
          '$maxEnrollmentRecordBytes byte limit');
    }
  }

  /// The exact string this enrollment publishes as its `_apsk`, or null when
  /// it publishes none.
  ///
  /// [EnrollDataStoreValue.apskLegacy] goes out verbatim and
  /// [EnrollDataStoreValue.apsk] JSON-encoded; the two are mutually exclusive.
  static String? _apskRecordValue(EnrollDataStoreValue enVal) {
    if (enVal.apskLegacy != null) {
      return enVal.apskLegacy;
    }
    if (enVal.apsk != null) {
      return jsonEncode(enVal.apsk);
    }
    return null;
  }

  /// Publishes the `_apsk` value the CLIENT composed at
  /// `public:_apsk.<enrollmentId>.a.__e@<atSign>`, world-readable so a
  /// verifier can reach it via plookup.
  ///
  /// A no-op when [enVal] carries neither shape. Takes the RECORD rather than
  /// a value, so an approver cannot substitute its own.
  Future<void> _publishApskSigningKey(
      String enrollmentId, EnrollDataStoreValue enVal, currentAtSign) async {
    final value = _apskRecordValue(enVal);
    if (value == null) {
      return;
    }
    final apskKey = 'public:_apsk.$enrollmentId'
        '.${EnrollmentConstants.perEnrollmentApproved}$currentAtSign';
    await keyStore.put(apskKey, AtData()..data = value);
  }

  EnrollmentStatus _getEnrollStatusEnum(String? enrollmentOperation) {
    enrollmentOperation = enrollmentOperation?.toLowerCase();
    final operationMap = {
      'approve': EnrollmentStatus.approved,
      'deny': EnrollmentStatus.denied,
      'revoke': EnrollmentStatus.revoked,
      'unrevoke': EnrollmentStatus.approved
    };

    return operationMap[enrollmentOperation] ?? EnrollmentStatus.pending;
  }

  /// `enroll:list`. The enrollments this caller may see, keyed by enrollment
  /// key, projected according to what the caller holds on `__manage`.
  Future<String> _fetchEnrollmentRequests(
      EnrollmentManager enMgr, AtConnection atConnection, String currentAtSign,
      {EnrollParams? enrollVerbParams}) async {
    final InboundConnectionMetadata md =
        atConnection.metaData as InboundConnectionMetadata;
    String? authenticatedEnrollmentId = md.enrollmentId;
    // A CRAM connection gets every enrollment whole.
    if (AbstractVerbHandler.isCramConnection(md)) {
      final enrollmentRequestsMap = await enMgr.getEnrollmentsAsJson(
        redactSecrets: false,
        statuses: enrollVerbParams?.enrollmentStatusFilter,
      );
      return jsonEncode(enrollmentRequestsMap);
    }
    if (authenticatedEnrollmentId == null ||
        authenticatedEnrollmentId.isEmpty) {
      throw UnAuthenticatedException(
          'enroll:list requires an enrollment or a CRAM connection');
    }

    // An APKAM connection sees every enrollment when its own holds `__manage`.
    EnrollDataStoreValue enrollDataStoreValue =
        await enMgr.getEnrollmentById(authenticatedEnrollmentId);

    if (_doesEnrollmentHaveManageNamespace(enrollDataStoreValue)) {
      // NOTE the projection turns on the caller's own __manage LETTER: a
      // read-only administrator can never approve, so it gets the roster.
      final bool callerMayApprove = EnrollmentAccess.allowsWrite(
          enrollDataStoreValue
              .namespaces[EnrollmentConstants.enrollManageNamespace]);
      final jsonMap = await enMgr.getEnrollmentsAsJson(
        redactSecrets: !callerMayApprove,
        statuses: enrollVerbParams?.enrollmentStatusFilter,
      );
      return jsonEncode(jsonMap);
    } else {
      final jsonMap = {};
      if (enrollDataStoreValue.approval!.state !=
          EnrollmentStatus.expired.name) {
        // The caller's OWN record, whole.
        String ek = enMgr.buildEnrollmentKey(authenticatedEnrollmentId);
        jsonMap[ek] = enrollDataStoreValue.toJsonExtended()
          ..['expiresAt'] = EnrollmentManager.expiresAtField(
              await enMgr.effectiveExpiryOf(ek));
      }
      return jsonEncode(jsonMap);
    }
  }

  /// Returns a JSON-encoded list of approved enrollments authorised for
  /// [namespace]. Each element has shape:
  ///   `{"enrollmentId": <id>, "access": <"r"|"rw">, "metadata": <map|null>}`
  Future<String> _fetchEnrollmentsForNamespace(
    EnrollmentManager enMgr,
    InboundConnection atConnection,
    String namespace,
  ) async {
    if (namespace.isEmpty) {
      throw IllegalArgumentException('namespace is required for enroll:listns');
    }

    await _requireNamespaceAccess(enMgr, atConnection, namespace, 'listns');
    final members = await enMgr.getEnrollmentsForNamespace(namespace);
    return jsonEncode(members);
  }

  /// Facts about [namespace] itself, as opposed to the roster of enrollments
  /// holding it.
  ///
  /// `lastRevokedAt` is present always, null when nothing holding the
  /// namespace has been revoked, and it can move BACKWARDS: compare it for
  /// inequality rather than ordering it.
  Future<String> _fetchNamespaceInfo(
    EnrollmentManager enMgr,
    InboundConnection atConnection,
    String namespace,
  ) async {
    if (namespace.isEmpty) {
      throw IllegalArgumentException('namespace is required for enroll:infons');
    }
    await _requireNamespaceAccess(enMgr, atConnection, namespace, 'infons');
    final DateTime? lastRevokedAt =
        await enMgr.lastRevocationForNamespace(namespace);
    return jsonEncode({'lastRevokedAt': lastRevokedAt?.toIso8601String()});
  }

  /// The gate both namespace-scoped verbs sit behind: an APKAM-authenticated
  /// caller whose own enrollment is approved and which holds at least read
  /// access to [namespace].
  Future<void> _requireNamespaceAccess(
    EnrollmentManager enMgr,
    InboundConnection atConnection,
    String namespace,
    String operation,
  ) async {
    final callerEnrollmentId =
        (atConnection.metaData as InboundConnectionMetadata).enrollmentId;
    if (callerEnrollmentId == null || callerEnrollmentId.isEmpty) {
      throw UnAuthenticatedException(
          'enroll:$operation requires APKAM authentication');
    }
    final callerEnVal = await enMgr.getEnrollmentById(callerEnrollmentId);
    if (callerEnVal.approval?.state != EnrollmentStatus.approved.name) {
      throw UnAuthorizedException('Caller enrollment is not in approved state');
    }
    if (enMgr.accessForNamespace(callerEnVal, namespace) == null) {
      throw UnAuthorizedException(
          'Caller enrollment is not authorised for namespace "$namespace"');
    }
    // NOTE `*` does not imply `__manage`: the matcher above falls back to the
    // wildcard for any namespace with no explicit grant.
    if (namespace == EnrollmentConstants.enrollManageNamespace &&
        !_doesEnrollmentHaveManageNamespace(callerEnVal)) {
      throw UnAuthorizedException(
          'Caller enrollment is not authorised for namespace "$namespace":'
          ' it must be held explicitly, and a `*` grant does not confer it');
    }
  }

  /// Whether the enrollment holds `__manage` EXPLICITLY; a `*` grant does not
  /// satisfy this.
  bool _doesEnrollmentHaveManageNamespace(
      EnrollDataStoreValue enrollDataStoreValue) {
    return enrollDataStoreValue.namespaces
        .containsKey(EnrollmentConstants.enrollManageNamespace);
  }

  /// Announces a pending enrollment to approver apps as a self notification
  /// keyed `<enrollmentId>.new.enrollments.__manage`, carrying the encrypted
  /// APKAM symmetric key.
  Future<void> _storeNotification(
      String key, EnrollParams enrollParams, String atSign) async {
    AtNotification? atNotification;
    try {
      var notificationValue = {};
      notificationValue[AtConstants.apkamEncryptedSymmetricKey] =
          enrollParams.encryptedAPKAMSymmetricKey;
      // NOTE both spellings go out; dropping either is a wire change.
      notificationValue['encryptedAPKAMSymmetricKey'] =
          enrollParams.encryptedAPKAMSymmetricKey;
      notificationValue[AtConstants.appName] = enrollParams.appName;
      notificationValue[AtConstants.deviceName] = enrollParams.deviceName;
      notificationValue[AtConstants.namespace] = enrollParams.namespaces;
      logger.finer('notificationValue:$notificationValue');
      atNotification = (AtNotificationBuilder()
            ..notification = key
            ..fromAtSign = atSign
            ..toAtSign = atSign
            ..ttl = 24 * 60 * 60 * 1000
            ..type = NotificationType.self
            ..opType = OperationType.update
            ..atValue = jsonEncode(notificationValue))
          .build();
      await notifManager.notify(atNotification);
      logger.finer('notification generated with id: ${atNotification.id}');
    } catch (e, trace) {
      logger.severe(
          'Exception while storing notification (id: ${atNotification?.id}). Exception $e. Trace $trace');
      rethrow;
    }
  }

  /// Throws [IllegalStateException] when [enrollStatus] is not a state
  /// [operation] may act on.
  void _verifyEnrollmentStateBeforeAction(
      String? operation, EnrollmentStatus enrollStatus) {
    if (operation == 'approve' && EnrollmentStatus.pending != enrollStatus) {
      throw IllegalStateException(
          'Cannot approve a ${enrollStatus.name} enrollment. Only pending enrollments can be approved');
    }
    if (operation == 'deny' && EnrollmentStatus.pending != enrollStatus) {
      throw IllegalStateException(
          'Cannot deny a ${enrollStatus.name} enrollment. Only pending enrollments can be denied');
    }
    if (operation == 'revoke' && EnrollmentStatus.approved != enrollStatus) {
      throw IllegalStateException(
          'Cannot revoke a ${enrollStatus.name} enrollment. Only approved enrollments can be revoked');
    }
    if (operation == 'delete' &&
        !(EnrollmentStatus.denied == enrollStatus ||
            EnrollmentStatus.revoked == enrollStatus)) {
      throw IllegalStateException(
          'Cannot delete ${enrollStatus.name} enrollments. Only denied and revoked enrollments can be deleted');
    }
    if (operation == 'unrevoke' && EnrollmentStatus.revoked != enrollStatus) {
      throw IllegalStateException(
          'Cannot un-revoke a ${enrollStatus.name} enrollment. Only revoked enrollments can be un-revoked');
    }
  }

  /// Whether [md] carries an enrollment: an authenticated connection holding a
  /// non-empty enrollment id. This, and not the auth type, selects the
  /// retrofit branch of the request path and the exemptions that go with it.
  @visibleForTesting
  static bool carriesEnrollment(InboundConnectionMetadata md) {
    final String? id = md.enrollmentId;
    return md.isAuthenticated && id != null && id.isNotEmpty;
  }

  /// Whether a retrofit of [predecessorId] has already capped it: a stored
  /// enrollment naming it as the one it replaced, whose cap is armed.
  Future<bool> _retrofitCapAlreadyArmed(
      EnrollmentManager enMgr, String predecessorId) async {
    final String canonical =
        EnrollmentManager.canonicalEnrollmentId(predecessorId);
    for (final (_, EnrollDataStoreValue existing)
        in await enMgr.storedEnrollments()) {
      if (existing.predecessorSettledAt == null) continue;
      if (EnrollmentManager.canonicalEnrollmentIdOrNull(
              existing.retrofitPredecessorEnrollmentId) ==
          canonical) {
        return true;
      }
    }
    return false;
  }

  /// Refuses a request whose (appName, deviceName) an approved or pending
  /// enrollment already holds, with [IllegalStateException].
  ///
  /// Read off the stored roster rather than the visible one.
  @visibleForTesting
  Future<void> preventDuplicateEnrollRequest(EnrollParams enrollParams) async {
    for (final (String enrollmentId, EnrollDataStoreValue existing)
        in await enMgr.storedEnrollments()) {
      if (enrollParams.appName == existing.appName &&
          enrollParams.deviceName == existing.deviceName &&
          (existing.approval?.state == EnrollmentStatus.approved.name ||
              existing.approval?.state == EnrollmentStatus.pending.name)) {
        throw IllegalStateException(
            'Another enrollment with id $enrollmentId exists with the app name: ${enrollParams.appName} and device name: ${enrollParams.deviceName} in ${existing.approval?.state} state');
      }
    }
  }

  /// Refuses to install [apkamPublicKey] when a stored enrollment, in ANY
  /// status, already holds that key material, with [IllegalStateException],
  /// and before anything is written.
  ///
  /// [excluding] is the enrollment re-sending its own current key. The
  /// refusal names the holding enrollment only under `testingMode`.
  Future<void> _refuseKeyHeldByAnotherEnrollment(
      String apkamPublicKey, String? signingAlgo,
      {String? excluding}) async {
    final (String, EnrollDataStoreValue)? holder = await enMgr
        .holderOfApkamPublicKey(apkamPublicKey, signingAlgo,
            excluding: excluding);
    if (holder == null) return;
    final (String holderId, EnrollDataStoreValue value) = holder;
    logger.warning('Refusing to install an APKAM public key that enrollment '
        '$holderId (${value.approval?.state}) already holds');
    final String named = AtSecondaryConfig.testingMode
        ? ' (held by enrollment $holderId, ${value.approval?.state})'
        : '';
    throw IllegalStateException(
        'The apkamPublicKey is already held by another enrollment on this '
        'atSign; every enrollment needs a keypair of its own$named');
  }

  /// Throws [IllegalArgumentException] if parameters are not valid.
  void _validateParams(EnrollParams? enrollParams, String operation,
      InboundConnection inboundConnection) {
    switch (operation) {
      case 'request':
        if (enrollParams!.appName.isNullOrEmpty) {
          throw IllegalArgumentException(
              'appName is mandatory for enroll:request');
        }

        if (enrollParams.deviceName.isNullOrEmpty) {
          throw IllegalArgumentException(
              'deviceName is mandatory for enroll:request');
        }

        if (enrollParams.apkamPublicKey.isNullOrEmpty) {
          throw IllegalArgumentException(
              'apkam public key is mandatory for enroll:request');
        }

        if (enrollParams.otp != null) {
          // NOTE not required when the request advertises a key package:
          // such a client never generates the symmetric key.
          if (enrollParams.encryptedAPKAMSymmetricKey.isNullOrEmpty &&
              enrollParams.metadata?['keyPackage'] == null) {
            throw IllegalArgumentException(
                'encrypted apkam symmetric key is mandatory for new client enroll:request');
          }
        }

        // Outside the OTP branch deliberately: an empty map lands an
        // enrollment no caller can demonstrate authority over. ⚠️ The
        // exemption must be keyed exactly as the request path's branches are.
        final InboundConnectionMetadata md =
            inboundConnection.metaData as InboundConnectionMetadata;
        if (!AbstractVerbHandler.isCramConnection(md) &&
            !carriesEnrollment(md) &&
            (enrollParams.namespaces == null ||
                enrollParams.namespaces!.isEmpty)) {
          throw IllegalArgumentException(
              'At least one namespace must be specified for enroll:request');
        }

        // The one place a spelling the server will not act on can be kept
        // out of the store. See [EnrollmentAccess].
        enrollParams.namespaces?.forEach((namespace, access) {
          if (EnrollmentAccess.canonicalise(access) == null) {
            throw IllegalArgumentException(
                'Invalid access "$access" for namespace "$namespace" in '
                'enroll:request. Valid values are '
                '${EnrollmentAccess.canonicalSpellings.join(' and ')}');
          }
        });

        break;
      case 'approve':
        if (enrollParams!.enrollmentId.isNullOrEmpty) {
          throw IllegalArgumentException(
              'enrollmentId is mandatory for enroll:approve');
        }
        if (enrollParams.encryptedDefaultEncryptionPrivateKey.isNullOrEmpty) {
          throw IllegalArgumentException(
              'encryptedDefaultEncryptionPrivateKey is mandatory for enroll:approve');
        }
        if (enrollParams.encryptedDefaultSelfEncryptionKey.isNullOrEmpty) {
          throw IllegalArgumentException(
              'encryptedDefaultSelfEncryptionKey is mandatory for enroll:approve');
        }
        break;
      case 'revoke':
      case 'deny':
      case 'delete':
      case 'unrevoke':
      case 'fetch':
        if (enrollParams!.enrollmentId.isNullOrEmpty) {
          throw IllegalArgumentException(
              'enrollmentId is mandatory for enroll:$operation');
        }
        break;
      case 'update':
        if (enrollParams!.enrollmentId.isNullOrEmpty) {
          throw IllegalArgumentException(
              'enrollmentId is mandatory for enroll:update');
        }
        // An update naming nothing to change is a caller bug.
        if (enrollParams.apkamPublicKey == null &&
            enrollParams.signingAlgo == null &&
            enrollParams.apsk == null &&
            enrollParams.apskLegacy == null &&
            enrollParams.metadata == null) {
          throw IllegalArgumentException(
              'enroll:update must name at least one of apkamPublicKey, '
              'signingAlgo, apsk, apskLegacy or metadata');
        }
        // Refused explicitly rather than silently ignored.
        if (enrollParams.namespaces != null) {
          throw IllegalArgumentException(
              'enroll:update cannot change namespaces: an enrollment amending '
              'itself must not be able to widen its own grant');
        }
        break;
      // list, listns and infons carry no enrollParams.
    }
  }

  /// The next delay in milliseconds for an invalid OTP, advancing
  /// [delayForInvalidOTPSeries] Fibonacci-wise and holding at
  /// [maxDelayInMillis].
  @visibleForTesting
  int getDelayIntervalInMilliseconds() {
    if (delayForInvalidOTPSeries.last >= maxDelayInMillis) {
      return delayForInvalidOTPSeries.last;
    }
    int nextDelay = delayForInvalidOTPSeries.last +
        delayForInvalidOTPSeries[delayForInvalidOTPSeries.length - 2];
    if (nextDelay > maxDelayInMillis) {
      nextDelay = maxDelayInMillis;
    }
    delayForInvalidOTPSeries.add(nextDelay);
    delayForInvalidOTPSeries.remove(delayForInvalidOTPSeries.first);

    return delayForInvalidOTPSeries.last;
  }

  @override
  bool checkEnrollmentNamespaceAccess(String authorisedNamespaceAccess,
      {String enrolledNamespaceAccess = ''}) {
    if (enrolledNamespaceAccess.isEmpty) {
      return false;
    }
    // A caller holding write may act on any grant; one holding only read may
    // act only on a grant that is itself read-only.
    return EnrollmentAccess.allowsWrite(authorisedNamespaceAccess) ||
        (EnrollmentAccess.allowsRead(authorisedNamespaceAccess) &&
            !EnrollmentAccess.allowsWrite(enrolledNamespaceAccess));
  }

  /// NOT a part of API. Used for unit tests
  @visibleForTesting
  int getEnrollmentResponseDelayInMilliseconds() {
    return delayForInvalidOTPSeries.last;
  }

  Future<void> _deleteEnrollment(
      EnrollmentManager enMgr,
      EnrollParams? enrollParams,
      String atSign,
      Map responseJson,
      response,
      InboundConnection atConnection) async {
    // Read-decide-write from the first line, so the whole is one mutation.
    return enMgr.serialiseMutation(() => _deleteEnrollmentUnderLock(
        enMgr, enrollParams, responseJson, response, atConnection));
  }

  /// The read-decide-write half of [_deleteEnrollment], run under
  /// [EnrollmentManager.serialiseMutation].
  Future<void> _deleteEnrollmentUnderLock(
      EnrollmentManager enMgr,
      EnrollParams? enrollParams,
      Map responseJson,
      response,
      InboundConnection atConnection) async {
    // _validateParams has already refused a null enrollmentId.
    final String targetEnrollmentId = enrollParams!.enrollmentId!;
    EnrollDataStoreValue enVal =
        await enMgr.getEnrollmentById(targetEnrollmentId);

    // A caller may always delete its OWN enrollment, and a connection
    // carrying no enrollment id may delete any. Deleting ANOTHER requires
    // __manage AND access to EVERY namespace the target holds. Asked before
    // the status checks, so a refusal leaks no state.
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final callerEnrollmentId = inboundConnectionMetadata.enrollmentId;
    if (!AbstractVerbHandler.isCramConnection(inboundConnectionMetadata) &&
        callerEnrollmentId != targetEnrollmentId) {
      // NOTE a target holding NO namespaces fails closed: the loop below
      // passes an empty map vacuously, and each such loop carries this guard.
      if (enVal.namespaces.isEmpty) {
        throw UnAuthorizedException(
            'Not authorized to delete enrollment $targetEnrollmentId: it holds'
            ' no namespaces, so no caller can demonstrate authority over it.'
            ' Delete it from the enrollment itself, or from a CRAM'
            ' connection');
      }
      for (final MapEntry<String, String> entry in enVal.namespaces.entries) {
        final bool isAuthorised = await isAuthorized(inboundConnectionMetadata,
            namespace: entry.key,
            enrolledNamespaceAccess: entry.value,
            operation: 'delete');
        if (!isAuthorised) {
          throw UnAuthorizedException(
              'Not authorized to delete enrollment $targetEnrollmentId:'
              ' requires __manage and access to all of its namespaces');
        }
      }
    }

    EnrollmentStatus status =
        EnrollmentStatus.values.byName(enVal.approval!.state);
    if (EnrollmentStatus.expired == status) {
      response.isError = true;
      response.errorCode = 'AT0028';
      response.errorMessage =
          'enrollment_id: ${enrollParams.enrollmentId} is expired or invalid';
      return;
    }

    try {
      _verifyEnrollmentStateBeforeAction(
          EnrollOperationEnum.delete.name, status);
    } on IllegalStateException catch (e) {
      throw IllegalStateException(
          'Failed to delete enrollment id: ${enrollParams.enrollmentId}'
          ' | Cause: ${e.message}');
    }

    await enMgr.remove(
      enId: enrollParams.enrollmentId!,
    );

    responseJson['enrollmentId'] = enrollParams.enrollmentId;
    responseJson['status'] = 'deleted';
  }
}
