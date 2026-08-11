import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'abstract_verb_handler.dart';

/// Verb handler to process APKAM enroll requests
class EnrollVerbHandler extends AbstractVerbHandler {
  static Enroll enrollVerb = Enroll();

  /// Defaulting the initial delay to 1000 milliseconds (1 second).
  @visibleForTesting
  static int initialDelayInMilliseconds = 1000;

  /// A list storing a series of delay intervals for handling invalid OTP series.
  /// The series is initially set to [0, [initialDelayInMilliseconds]] and is updated using the Fibonacci sequence.
  @visibleForTesting
  List<int> delayForInvalidOTPSeries = <int>[0, initialDelayInMilliseconds];

  /// The maximum value for the delay interval in milliseconds.
  @visibleForTesting
  int maxDelayInMillis = Duration(
          seconds: AtSecondaryConfig.enrollmentResponseDelayIntervalInSeconds)
      .inMilliseconds;

  /// The largest `EnrollParams.apsk` the atServer will store, measured on its
  /// JSON encoding — the string that lands in the keystore.
  ///
  /// The value is opaque, so nothing about it can be validated; a bound is all
  /// the server can meaningfully impose. 20KB is far above any signing key
  /// (ML-DSA-65's public half is ~2.6KB base64-encoded, the largest in play)
  /// and far below anything that would make the enrollment record awkward to
  /// store or return from `enroll:listns`.
  static const int maxApskLengthBytes = 20 * 1024;

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
    // Approve, deny, revoke or list enrollments only on authenticated connections
    if (operation != 'request' && !atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException(
          'Cannot $operation enrollment without authentication');
    }
    EnrollParams? enrollVerbParams;

    // Ensure that enrollParams are present for all enroll operation.
    // 'list' and 'listns' carry no enrollParams JSON body.
    if (verbParams[AtConstants.enrollParams] == null) {
      if (operation != 'list' && operation != 'listns') {
        logger.severe(
            'Enroll params is empty | EnrollParams: ${verbParams[AtConstants.enrollParams]}');
        throw IllegalArgumentException('Enroll parameters not provided');
      }
    } else {
      enrollVerbParams = EnrollParams.fromJson(
          jsonDecode(verbParams[AtConstants.enrollParams]!)
              as Map<String, dynamic>);
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
        await _handleApproveDenyRevokeUnrevoke(
          enMgr,
          (atConnection.metaData as InboundConnectionMetadata),
          enrollVerbParams,
          currentAtSign,
          operation,
          responseJson,
          response,
        );
        if (responseJson['status'] == EnrollmentStatus.revoked.name) {
          logger.finer(
              'Dropping connection for enrollmentId: $enrollmentIdFromParams');
          await _dropRevokedClientConnection(enrollmentIdFromParams!,
              forceFlag != null, atConnection, responseJson);
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
    // Note: The enrollmentId is verified for null check in _validateParams.
    final String targetEnrollmentId = enrollVerbParams!.enrollmentId!;
    EnrollDataStoreValue enrollDataStoreValue =
        await enMgr.getEnrollmentById(targetEnrollmentId);

    // enroll:fetch returns the enrollment's encryptedAPKAMSymmetricKey (a
    // secret). A caller may always fetch its OWN enrollment (and a
    // no-enrollmentId CRAM/owner connection may fetch any). Fetching ANOTHER
    // enrollment requires __manage AND access to EVERY namespace the target
    // holds — the same bar as approve/deny/revoke.
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final callerEnrollmentId = inboundConnectionMetadata.enrollmentId;
    if (callerEnrollmentId != null &&
        callerEnrollmentId.isNotEmpty &&
        callerEnrollmentId != targetEnrollmentId) {
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

    return jsonEncode({
      'appName': enrollDataStoreValue.appName,
      'deviceName': enrollDataStoreValue.deviceName,
      'namespace': enrollDataStoreValue.namespaces,
      'encryptedAPKAMSymmetricKey':
          enrollDataStoreValue.encryptedAPKAMSymmetricKey,
      'status': enrollDataStoreValue.approval?.state
    });
  }

  /// Enrollment requests details are persisted in the keystore and are excluded from
  /// adding to the commit log to prevent the synchronization of enrollment
  /// keys with clients.
  ///
  /// If the enrollment request originates from a CRAM authenticated connection:
  ///
  /// The enrollment is automatically approved and given privilege to the "__manage"
  /// namespace group with "rw" access.
  /// The default encryption private key and default self-encryption key are
  /// securely stored in encrypted format within the keystore.
  ///
  /// If the enrollment request originates from an unauthenticated connection and
  /// includes a valid OTP (One-Time Password), it is marked as pending.
  ///
  ///
  /// The function returns a JSON-encoded string containing the enrollmentId
  /// and its corresponding state.
  ///
  /// Throws [IllegalArgumentException], if the OTP provided is invalid.
  /// Throws [AtThrottleLimitExceeded], if the number of requests exceed within
  /// a time window.
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

    // Bound the one field the server stores without understanding, before
    // anything is created or an OTP is spent. Refused rather than truncated:
    // a truncated signing key is a key nothing can verify against, published
    // at the address every verifier resolves, and the enrollee would have no
    // way to tell that from a key it composed wrong.
    final apskLength = enrollParams.apsk == null
        ? 0
        : utf8.encode(jsonEncode(enrollParams.apsk)).length;
    if (apskLength > maxApskLengthBytes) {
      throw IllegalArgumentException(
          'apsk is $apskLength bytes encoded, which exceeds the '
          '$maxApskLengthBytes byte limit');
    }

    // OTP is sent only in enrollment request which is submitted on
    // unauthenticated connection.
    if (atConnection.metaData.isAuthenticated == false) {
      var isValid = await isPasscodeValid(enrollParams.otp);
      if (!isValid) {
        // Invalid passcode, delay before responding.
        await Future.delayed(
            Duration(milliseconds: getDelayIntervalInMilliseconds()));
        throw IllegalArgumentException(
            'invalid otp. Cannot process enroll request');
      } else {
        // Valid passcode - reset the delay
        delayForInvalidOTPSeries.clear();
        delayForInvalidOTPSeries.addAll([0, initialDelayInMilliseconds]);
      }
    }

    if (atConnection.metaData.authType == AuthType.cram) {
      // A CRAM-authenticated connection is allowed a 'duplicate' enrollment
      // request. See #2208
      logger.warning('CRAM-authenticated connection - i.e. initial enrollment;'
          ' will replace the existing initial enrollment, if any');
    } else if (atConnection.metaData.authType == AuthType.apkam) {
      // An APKAM self-enrollment keeps its app's own (appName, deviceName):
      // a retrofit is the same app re-enrolling itself, and sibling clones of
      // one keyfile share those names, each needing to coexist with the
      // approved enrollments the others already spawned. Uniqueness of
      // (appName, deviceName) among live enrollments therefore ends on this
      // branch by design.
    } else {
      // Every other connection must not duplicate an existing enrollment's
      // (appName, deviceName).
      await preventDuplicateEnrollRequest(enrollParams);
    }

    var enrollNamespaces = enrollParams.namespaces ?? {};
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

    // The X-Wing key package (at `metadata.keyPackage`), the APKAM
    // `signingAlgo` and the client-composed `_apsk` value ride EnrollParams on
    // enroll:request and are persisted verbatim onto the enrollment record —
    // there is no separate enroll:metadata write.
    if (enrollParams.metadata != null) {
      enrollmentValue.metadata = enrollParams.metadata;
    }
    if (enrollParams.signingAlgo != null) {
      enrollmentValue.signingAlgo = enrollParams.signingAlgo;
    }
    if (enrollParams.apsk != null) {
      enrollmentValue.apsk = enrollParams.apsk;
    }

    if (enrollParams.apkamKeysExpiryDuration != null) {
      enrollmentValue.apkamKeysExpiryDuration =
          enrollParams.apkamKeysExpiryDuration!;
    }

    // We auto-approve enroll requests from a CRAM-authenticated connection.
    if (atConnection.metaData.authType != null &&
        atConnection.metaData.authType == AuthType.cram) {
      enrollNamespaces[EnrollmentConstants.enrollManageNamespace] = 'rw';
      enrollNamespaces[EnrollmentConstants.allNamespaces] = 'rw';
      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      responseJson['status'] = 'approved';
      final inboundConnectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      inboundConnectionMetadata.enrollmentId = newEnrollmentId;
      // store this apkam as default pkam public key for old clients
      // The keys with AT_PKAM_PUBLIC_KEY does not sync to client.
      await keyStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = enrollParams.apkamPublicKey!,
          skipCommit: true);
      // Publish the client-composed `_apsk` signing key, if it sent one.
      await _publishApskSigningKey(
          newEnrollmentId, enrollmentValue.apsk, currentAtSign);
      AtData enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());

      await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.approved);
      return;
    }

    // An APKAM-authenticated connection self-enrolls a FRESH enrollment —
    // RF-SRV, the "upgrade the enrollment" step every migration scenario in
    // at_client_sdk docs/projects/pq/decisions.md 36-40 conjugates. Auto-
    // approved with no human step and no OTP: the connection's existing
    // approved enrollment is the authority, and the child can hold at most
    // what the parent holds. The parent is capped, not removed, so sibling
    // clones of the same keyfile can still retrofit until the cap elapses.
    if (atConnection.metaData.authType == AuthType.apkam) {
      final inboundConnectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      final parentEnrollmentId = inboundConnectionMetadata.enrollmentId;
      if (parentEnrollmentId == null) {
        throw UnAuthorizedException(
            'An APKAM-authenticated self-enrollment needs a resolvable '
            'enrollment id on the connection');
      }
      final EnrollDataStoreValue parent;
      try {
        parent = await enMgr.getEnrollmentById(parentEnrollmentId);
      } on KeyNotFoundException {
        throw UnAuthorizedException(
            'Parent enrollment $parentEnrollmentId does not exist or has '
            'expired');
      }
      if (parent.approval?.state != EnrollmentStatus.approved.name) {
        throw UnAuthorizedException(
            'Parent enrollment $parentEnrollmentId is not approved');
      }
      // Reject escalation: every requested grant must be one the parent
      // itself holds. Without this, any scoped keyfile could self-spawn a
      // fully privileged enrollment.
      verifyNoEscalation(parent.namespaces, enrollNamespaces);

      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      // The child records its parent so revocation can CASCADE: a stolen
      // keyfile must not spawn a child that survives the parent's
      // revocation. (The cascade itself is the revoke path's to implement.)
      enrollmentValue.parentEnrollmentId = parentEnrollmentId;
      // The child inherits the parent's key-expiry posture unless the
      // request states its own.
      if (enrollParams.apkamKeysExpiryDuration == null) {
        enrollmentValue.apkamKeysExpiryDuration =
            parent.apkamKeysExpiryDuration;
      }
      // A stated posture may narrow the parent's, never widen it.
      // `verifyNoEscalation` covers namespaces; TIME is the other axis a
      // stolen keyfile would want to widen, and this branch is the one
      // enrollment path with no human in the loop to notice. Zero is the
      // keystore's "never expires" and a negative value skips the ttl write
      // altogether, so both are ways of asking for a permanent credential —
      // against a time-bound parent, neither is honoured.
      final parentExpiryMs = parent.apkamKeysExpiryDuration.inMilliseconds;
      final statedExpiryMs =
          enrollmentValue.apkamKeysExpiryDuration.inMilliseconds;
      if (statedExpiryMs < 0 ||
          (parentExpiryMs > 0 &&
              (statedExpiryMs <= 0 || statedExpiryMs > parentExpiryMs))) {
        logger.warning(
            'Self-enrollment under $parentEnrollmentId asked for a key-expiry '
            'of ${statedExpiryMs}ms against a parent bound to '
            '${parentExpiryMs}ms; using the parent\'s');
        enrollmentValue.apkamKeysExpiryDuration =
            parent.apkamKeysExpiryDuration;
      }
      // May be absent: a PQ self-enrollment conveys its legacy material
      // client-side, sealed to its own new key package.
      enrollmentValue.encryptedAPKAMSymmetricKey =
          enrollParams.encryptedAPKAMSymmetricKey;
      responseJson['status'] = 'approved';

      // Publish the client-composed `_apsk` signing key, if it sent one.
      await _publishApskSigningKey(
          newEnrollmentId, enrollmentValue.apsk, currentAtSign);
      // The child's record expires per its (inherited or stated) key-expiry
      // posture, exactly as the ordinary approve path writes it — the
      // retrofit copies the parent's expiry, it does not grant immortality.
      // A ttl of zero is the keystore's "never expires", matching a parent
      // with no posture.
      await enMgr.put(
          newEnrollmentId,
          AtData()
            ..data = jsonEncode(enrollmentValue.toJson())
            ..metaData = (AtMetaData()
              ..ttl = enrollmentValue.apkamKeysExpiryDuration.inMilliseconds),
          EnrollmentStatus.approved);

      // Cap the parent WITHOUT removing it, re-arming the cap on every
      // sibling retrofit: the legacy credential retires one grace period
      // after the LAST clone upgrades, never past the expiry its own
      // posture already imposes.
      await _capEnrollmentExpiry(parentEnrollmentId, parent);
      return;
    }

    // OK it's a standard enrollment request.
    // - send a notification to be received by an approver app
    // - store the enrollment in 'pending' state
    enrollmentValue.encryptedAPKAMSymmetricKey =
        enrollParams.encryptedAPKAMSymmetricKey;
    enrollmentValue.approval = EnrollApproval(EnrollmentStatus.pending.name);
    await _storeNotification(enrollmentKey, enrollParams, currentAtSign);
    responseJson['status'] = 'pending';
    AtData enrollData = AtData()
      ..data = jsonEncode(enrollmentValue.toJson())
      // Set TTL to the pending enrollments.
      // The enrollments will expire after configured
      // expiry limit, beyond which any action (approve/deny/revoke) on an
      // enrollment is forbidden
      ..metaData = (AtMetaData()..ttl = enrollmentExpiryInMills);

    await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.pending);
  }

  /// Rejects any requested grant the parent enrollment does not itself hold.
  ///
  /// Subset per namespace and per access letter: `r` fits under `rw`, never
  /// the reverse. A parent's `*` grant covers any ordinary namespace at the
  /// letters it carries — mirroring the server's own authorisation — but
  /// `__manage` and `*` themselves must be held literally: `*` does not imply
  /// `__manage` anywhere else in the server, and it must not here.
  @visibleForTesting
  void verifyNoEscalation(
      Map<String, String> parentGrants, Map<String, String> requested) {
    for (final entry in requested.entries) {
      String? parentAccess = parentGrants[entry.key];
      final isSpecial = entry.key == EnrollmentConstants.allNamespaces ||
          entry.key == EnrollmentConstants.enrollManageNamespace;
      if (parentAccess == null && !isSpecial) {
        parentAccess = parentGrants[EnrollmentConstants.allNamespaces];
      }
      final held = parentAccess;
      if (held == null ||
          !entry.value.split('').every(held.split('').contains)) {
        throw UnAuthorizedException(
            'Requested namespace "${entry.key}:${entry.value}" exceeds the '
            'parent enrollment\'s grants — a self-enrollment can hold at '
            'most what its parent holds');
      }
    }
  }

  /// Caps [enrollmentId] to expire `min(now + grace, its own expiry)` from
  /// this moment, leaving the record in place.
  ///
  /// Re-applied on EVERY self-enrollment, computed fresh from the record's
  /// own posture rather than folded into a previously written cap: sibling
  /// clones of one keyfile retrofit whenever each device next runs, so the
  /// cap must RE-ARM with each retrofit — a deadline fixed by the first
  /// sibling's upgrade would strand every laggard whose next run falls
  /// outside that first window. "Its own expiry" is re-derived from
  /// [EnrollDataStoreValue.apkamKeysExpiryDuration], anchored at the
  /// record's creation, so a key-expiry posture shorter than the grace
  /// still wins.
  ///
  /// A written ttl anchors at the write (`expiresAt = now + ttl` in the
  /// metadata builder), so the grace is written as-is — offsetting it by the
  /// record's age would extend the cap by the enrollment's whole lifetime.
  Future<void> _capEnrollmentExpiry(
      String enrollmentId, EnrollDataStoreValue enrollment) async {
    final key = enMgr.buildEnrollmentKey(enrollmentId);
    final AtData? atData;
    try {
      atData = await keyStore.get(key);
    } on KeyNotFoundException {
      return;
    }
    if (atData == null) return;
    final now = DateTime.now().toUtc();
    int cappedTtl =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;
    final ownMs = enrollment.apkamKeysExpiryDuration.inMilliseconds;
    if (ownMs > 0) {
      final createdAt = (atData.metaData?.createdAt ?? now).toUtc();
      final ownRemainingMs = createdAt
          .add(Duration(milliseconds: ownMs))
          .difference(now)
          .inMilliseconds;
      if (ownRemainingMs < cappedTtl) cappedTtl = ownRemainingMs;
    }
    // A ttl of zero means "never expires", and a spent posture must not
    // become immortality — floor at one millisecond.
    if (cappedTtl < 1) cappedTtl = 1;
    atData.metaData = (atData.metaData ?? AtMetaData())..ttl = cappedTtl;
    await enMgr.put(enrollmentId, atData, EnrollmentStatus.approved);
  }

  /// Handles enrollment approve, deny, revoke and unrevoke requests.
  /// Retrieves enrollment details from keystore and updates the enrollment status based on [operation]
  /// If [operation] is approve, store encrypted encryption keys
  Future<void> _handleApproveDenyRevokeUnrevoke(
      EnrollmentManager enMgr,
      InboundConnectionMetadata inboundConnectionMetadata,
      EnrollParams enrollParams,
      currentAtSign,
      String operation,
      Map<dynamic, dynamic> responseJson,
      Response response) async {
    // Note: The enrollParams.enrollmentId is verified for null check in _validateParams method.
    // Therefore, when control comes here, enrollmentId will not be null.
    final String enId = enrollParams.enrollmentId!;
    EnrollDataStoreValue? enVal;
    EnrollmentStatus? status;
    try {
      enVal = await enMgr.getEnrollmentById(enId);
    } on KeyNotFoundException {
      // When an enrollment key is expired or invalid
      status = EnrollmentStatus.expired;
    }
    status ??= EnrollmentStatus.values.byName(enVal!.approval!.state);
    // Validates if enrollment is not expired
    if (EnrollmentStatus.expired == status) {
      response.isError = true;
      response.errorCode = 'AT0028';
      response.errorMessage = 'enrollment_id: $enId is expired or invalid';
      return;
    }

    // Verifies whether the enrollment state matches the intended state
    // Throws IllegalStateException, if the enrollment state is different from
    // the intended state
    try {
      _verifyEnrollmentStateBeforeAction(operation, status);
    } on IllegalStateException catch (e) {
      throw IllegalStateException(
          'Failed to $operation enrollment id: $enId. ${e.message}');
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

    EnrollmentStatus newEnrollmentStatus = _getEnrollStatusEnum(operation);
    enVal.approval!.state = newEnrollmentStatus.name;
    responseJson['status'] = newEnrollmentStatus.name;

    // Update the enrollment status against the enrollment key in keystore.
    AtData atData = AtData()..data = jsonEncode(enVal.toJson());
    // If an enrollment is approved, we need the enrollment to be active
    // to subsequently revoke the enrollment. Hence reset TTL and
    // expiredAt on metadata.
    if (operation == 'approve') {
      // Fetch the existing data
      String ek = enMgr.buildEnrollmentKey(enId);
      AtMetaData emd = await keyStore.getMeta(ek) ?? AtMetaData();
      // Update key with new data
      // Update ttl value to support auto expiry of APKAM keys
      emd.ttl = enVal.apkamKeysExpiryDuration.inMilliseconds;
      atData.metaData = emd;
    }
    await enMgr.put(enId, atData, newEnrollmentStatus);

    // when enrollment is approved store the encrypted encryption keys
    if (operation == 'approve') {
      await _storeEncryptionKeys(enId, enrollParams, enVal);
      // Publish the `_apsk` signing key the enrollee composed on its request.
      // Read off the RECORD, not off these approve params: the value is the
      // enrollee's, and an approver must not be able to substitute a signing
      // key for the enrollment it is approving.
      await _publishApskSigningKey(enId, enVal.apsk, currentAtSign);
    }
    responseJson['enrollmentId'] = enId;
  }

  /// `enroll:update` — an approved enrollment amending its OWN record.
  ///
  /// Reaches `apkamPublicKey`, `signingAlgo`, `apsk` and `metadata`, and
  /// nothing else. `namespaces` and the approval state are permanently out of
  /// reach: this operation is self-only, so an enrollment that could reach
  /// them could widen its own grant, which is privilege escalation with a
  /// valid signature on it.
  ///
  /// Replacing `apkamPublicKey` is how an enrollment rotates its
  /// authentication keypair while keeping its id. Before this existed the only
  /// route was a new enrollment, which strands every record addressed to the
  /// old id.
  ///
  /// Metadata is a per-key set, never a whole-map replace: keys the request
  /// does not name survive untouched. A whole-map replace is read-mutate-write
  /// against shared durable state, so a client that does not know about a
  /// future sibling field would clobber it.
  Future<void> _handleEnrollmentUpdate(
    EnrollmentManager enMgr,
    InboundConnectionMetadata connectionMetadata,
    EnrollParams enrollParams,
    String currentAtSign,
    Map<dynamic, dynamic> responseJson,
    Response response,
  ) async {
    final enId = enrollParams.enrollmentId!;

    // Self-only. An explicit exception to `isAuthorized`'s "no enrollmentId
    // means full permissions" default: an owner or legacy-PKAM connection is
    // refused here, not waved through. An owner cannot sign anything with this
    // enrollment's APKAM private, so anything it wrote would fail every
    // reader's verification and buys only a denial of service — and self-only
    // is what makes replace semantics safe, because the only party who can
    // reinstate a stale value is the holder of the key it was signed with.
    if (connectionMetadata.enrollmentId != enId) {
      throw AtEnrollmentException(
          'enroll:update is self-only: this connection is authenticated as '
          '${connectionMetadata.enrollmentId ?? "the owner"}, not $enId');
    }

    final enVal = await enMgr.getEnrollmentById(enId);
    final status = EnrollmentStatus.values.byName(enVal.approval!.state);
    if (status != EnrollmentStatus.approved) {
      throw AtEnrollmentException(
          'enroll:update requires an approved enrollment; $enId is '
          '${status.name}');
    }

    // Same cap and the same reason as enroll:request: an oversized value is
    // refused before anything is written, never truncated, because a truncated
    // signing key is a key nothing can verify against sitting at the address
    // every verifier resolves.
    if (enrollParams.apsk != null) {
      final apskLength = utf8.encode(jsonEncode(enrollParams.apsk)).length;
      if (apskLength > maxApskLengthBytes) {
        throw IllegalArgumentException(
            'apsk is $apskLength bytes encoded, which exceeds the '
            '$maxApskLengthBytes byte limit');
      }
    }

    if (enrollParams.apkamPublicKey != null) {
      final newSigningAlgo = enrollParams.signingAlgo ?? enVal.signingAlgo;
      await _verifyApkamPublicKeyPossession(
        enrollmentId: enId,
        apkamPublicKey: enrollParams.apkamPublicKey!,
        signingAlgo: newSigningAlgo,
        signature: enrollParams.apkamPublicKeySignature,
      );
      enVal.apkamPublicKey = enrollParams.apkamPublicKey!;
      if (enrollParams.signingAlgo != null) {
        enVal.signingAlgo = enrollParams.signingAlgo;
      }
    } else if (enrollParams.signingAlgo != null) {
      // The algorithm describes the key, so moving one without the other would
      // leave the record claiming a spelling its key is not in — and PKAM
      // verification is record-authoritative, so that record is what every
      // later authentication is judged against.
      throw IllegalArgumentException(
          'signingAlgo cannot be changed without apkamPublicKey: the '
          'algorithm describes the key');
    }

    if (enrollParams.apsk != null) {
      enVal.apsk = enrollParams.apsk;
    }

    if (enrollParams.metadata != null) {
      final merged = Map<String, dynamic>.from(enVal.metadata ?? {});
      merged.addAll(enrollParams.metadata!);
      enVal.metadata = merged;
    }

    // The state and TTL are untouched: this is the same put the approve path
    // uses, with an already-approved status, so nothing about the enrollment's
    // lifecycle moves.
    await enMgr.put(
        enId, AtData()..data = jsonEncode(enVal), EnrollmentStatus.approved);

    // Republish only when the request carried a new value. An update that says
    // nothing about apsk leaves the published record exactly as it was.
    if (enrollParams.apsk != null) {
      await _publishApskSigningKey(enId, enVal.apsk, currentAtSign);
    }

    responseJson['enrollmentId'] = enId;
    responseJson['status'] = EnrollmentStatus.approved.name;
  }

  /// Verifies that whoever sent this `enroll:update` holds the private half of
  /// the [apkamPublicKey] it is asking to install.
  ///
  /// The connection proves possession of the enrollment's **current** key;
  /// nothing else proves possession of the new one. Without this check a
  /// compromised-but-authenticated client can install a public key whose
  /// private half is held by an attacker, locking out the legitimate holder
  /// while the enrollment record still looks entirely valid.
  ///
  /// The signature covers `<enrollmentId>|<apkamPublicKey>|<signingAlgo>` and
  /// is verified against the new public key carried in the same request —
  /// a self-signature, which is exactly what proof of possession is.
  ///
  /// No nonce, deliberately: the operation is self-only over an authenticated
  /// connection, and the old key stops authenticating the moment the rotation
  /// lands, so a replayed request can only be sent by the current holder. That
  /// makes a rollback self-harm rather than an attack.
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

    // Verified through the same AtChops compatibility API `pkam_verb_handler`
    // uses, deprecated and all. That is deliberate: PKAM is the other place
    // that verifies an APKAM signature against a record's algorithm, and two
    // verification paths that have to agree byte-for-byte about how a
    // signature is framed is a worse problem than one shared deprecation.
    // Migrate both to AtSignatureAlgorithm.verifyBytes together, once at_chops
    // offers a SigningAlgoType-to-algorithm dispatcher.
    final signable = '$enrollmentId|$apkamPublicKey|$signingAlgo';
    final verificationInput = AtSigningVerificationInput(
        utf8.encode(signable), base64Decode(signature), apkamPublicKey)
      ..signingAlgoType = _signingAlgoTypeOf(signingAlgo)
      ..hashingAlgoType = HashingAlgoType.sha256
      // pkam, not data: AtSigningMode.data signs with the ENCRYPTION keypair,
      // and what is being proved here is possession of an APKAM signing key.
      // It is also the mode PKAM verification itself uses, so the two agree
      // about how the bytes are framed.
      ..signingMode = AtSigningMode.pkam;

    bool verified = false;
    try {
      // await, because AtSigningResult.result is a FutureOr<bool>: at_chops
      // verifies mldsa65 asynchronously and the other algorithms
      // synchronously, while AtChopsImpl.verify is synchronous either way.
      // Awaiting a non-Future returns it unchanged, so both arrive as a bool.
      verified = await AtChopsImpl(AtChopsKeys.create(null, null))
          .verify(verificationInput)
          .result;
    } on Exception catch (e) {
      logger.finer('apkamPublicKeySignature verification threw: $e');
    }
    if (!verified) {
      throw AtEnrollmentException(
          'apkamPublicKeySignature does not verify against the '
          'apkamPublicKey being installed');
    }
  }

  /// The [SigningAlgoType] a `signingAlgo` token names.
  ///
  /// Defaults to `rsa2048` for an absent token, matching PKAM's own
  /// resolution, so a record written before the field existed keeps behaving
  /// as it always did.
  SigningAlgoType _signingAlgoTypeOf(String? signingAlgo) =>
      switch (signingAlgo) {
        'ecc_secp256r1' => SigningAlgoType.ecc_secp256r1,
        'mldsa65' => SigningAlgoType.mldsa65,
        _ => SigningAlgoType.rsa2048,
      };

  Future<void> _dropRevokedClientConnection(String enrollmentId, bool forceFlag,
      InboundConnection currentInboundConnection, responseJson) async {
    final inboundPool =
        AtSecondaryServerImpl.getInstance().inboundConnectionManager.pool;
    List<InboundConnection> connectionsToRemove = [];
    for (InboundConnection connection in inboundPool.getConnections()) {
      var inboundConnectionMetadata =
          connection.metaData as InboundConnectionMetadata;
      if (!connection.isInValid() &&
          inboundConnectionMetadata.enrollmentId == enrollmentId) {
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

  /// Stores the encrypted default encryption private key
  /// in `<enrollmentId>.default_enc_private_key.__manage@<atsign>`
  /// and the encrypted self encryption key
  /// in `<enrollmentId>.default_self_enc_key.__manage@<atsign>`
  /// These keys will be stored only on server and will not be synced to the
  /// client. Encrypted keys will be used later on by the approving app to
  /// send the keys to a new enrolling app
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

  /// Publishes [apsk] — the value the CLIENT composed and sent on
  /// `enroll:request` — at `public:_apsk.<enrollmentId>.a.__e@<atSign>`, the
  /// location the at_client `ApkamSigning` mixin reads.
  ///
  /// A no-op when [apsk] is null. The atServer composes nothing: PKAM
  /// verification reads the enrollment record's `apkamPublicKey` and
  /// `signingAlgo`, so `_apsk` is a client-side artefact and its format
  /// belongs to the side that parses it. An enrollment that sent no value
  /// publishes its own signing key from its own connection, or goes without.
  ///
  /// The server writes it despite never reading it because `_apsk` accepts
  /// writes only from its own enrollment's connection, and at approval that
  /// connection has never existed. The approver needs the record immediately —
  /// it verifies the enrollee's key package against it and signs signing-chain
  /// links over it — so this is the only party that can put it there in time.
  ///
  /// World-readable, so a same-atSign or peer-atSign verifier can reach it via
  /// plookup. Idempotent: a re-publish is a harmless overwrite with the same
  /// value.
  Future<void> _publishApskSigningKey(
      String enrollmentId, Map<String, dynamic>? apsk, currentAtSign) async {
    if (apsk == null) {
      return;
    }
    final apskKey = 'public:_apsk.$enrollmentId'
        '.${EnrollmentConstants.perEnrollmentApproved}$currentAtSign';
    await keyStore.put(apskKey, AtData()..data = jsonEncode(apsk));
  }

  EnrollmentStatus _getEnrollStatusEnum(String? enrollmentOperation) {
    enrollmentOperation = enrollmentOperation?.toLowerCase();
    final operationMap = {
      'approve': EnrollmentStatus.approved,
      'deny': EnrollmentStatus.denied,
      'revoke': EnrollmentStatus.revoked,
      // If an enrollment is un-revoked, then it should be go back to approved state to authenticate with the APKAM keys
      // corresponding to the enrollment-id. Therefore setting "EnrollmentStatus.approved"
      'unrevoke': EnrollmentStatus.approved
    };

    return operationMap[enrollmentOperation] ?? EnrollmentStatus.pending;
  }

  /// Returns a Map where key is an enrollment key and value is a
  /// Map of "appName","deviceName" and "namespaces"
  Future<String> _fetchEnrollmentRequests(
      EnrollmentManager enMgr, AtConnection atConnection, String currentAtSign,
      {EnrollParams? enrollVerbParams}) async {
    String? authenticatedEnrollmentId =
        (atConnection.metaData as InboundConnectionMetadata).enrollmentId;
    // If connection is authenticated via legacy PKAM, then enrollApprovalId is null.
    // Return all the enrollments.
    if (authenticatedEnrollmentId == null ||
        authenticatedEnrollmentId.isEmpty) {
      final enrollmentRequestsMap = await enMgr.getEnrollmentsAsJson(
        statuses: enrollVerbParams?.enrollmentStatusFilter,
      );
      return jsonEncode(enrollmentRequestsMap);
    }

    // If connection is authenticated via APKAM, then enrollApprovalId is populated,
    // check if the enrollment has access to __manage namespace.
    // If enrollApprovalId has access to __manage namespace, return all the enrollments,
    // Else return only the specific enrollment.
    EnrollDataStoreValue enrollDataStoreValue =
        await enMgr.getEnrollmentById(authenticatedEnrollmentId);

    if (_doesEnrollmentHaveManageNamespace(enrollDataStoreValue)) {
      final jsonMap = await enMgr.getEnrollmentsAsJson(
        statuses: enrollVerbParams?.enrollmentStatusFilter,
      );
      return jsonEncode(jsonMap);
    } else {
      final jsonMap = {};
      if (enrollDataStoreValue.approval!.state !=
          EnrollmentStatus.expired.name) {
        String ek = enMgr.buildEnrollmentKey(authenticatedEnrollmentId);
        jsonMap[ek] = enrollDataStoreValue.toJsonExtended();
      }
      return jsonEncode(jsonMap);
    }
  }

  /// Returns a JSON-encoded list of approved enrollments authorised for
  /// [namespace]. Each element has shape:
  ///   `{"enrollmentId": <id>, "access": <"r"|"rw">, "metadata": <map|null>}`
  ///
  /// Only enrollments with at least read-access to [namespace] are included.
  /// Requires an APKAM-authenticated connection that itself has access to the
  /// namespace (the atServer namespace gating ensures this implicitly; the
  /// handler re-verifies that the caller's enrollment is approved).
  Future<String> _fetchEnrollmentsForNamespace(
    EnrollmentManager enMgr,
    InboundConnection atConnection,
    String namespace,
  ) async {
    if (namespace.isEmpty) {
      throw IllegalArgumentException('namespace is required for enroll:listns');
    }

    final callerEnrollmentId =
        (atConnection.metaData as InboundConnectionMetadata).enrollmentId;
    if (callerEnrollmentId == null || callerEnrollmentId.isEmpty) {
      throw UnAuthenticatedException(
          'enroll:listns requires APKAM authentication');
    }

    // Verify the caller's own enrollment is approved AND holds at least read
    // access to the requested namespace — learning a namespace's roster is
    // gated on ≥r for that namespace, not merely on being approved.
    final callerEnVal = await enMgr.getEnrollmentById(callerEnrollmentId);
    if (callerEnVal.approval?.state != EnrollmentStatus.approved.name) {
      throw UnAuthorizedException('Caller enrollment is not in approved state');
    }
    if (_accessForNamespace(callerEnVal, namespace) == null) {
      throw UnAuthorizedException(
          'Caller enrollment is not authorised for namespace "$namespace"');
    }

    final members = await enMgr.getEnrollmentsForNamespace(namespace);
    return jsonEncode(members);
  }

  /// The caller's access (`r`|`rw`) to [namespace] under the atServer's own
  /// suffix / `*`-wildcard rule, or null if the enrollment has no access.
  /// Mirrors [EnrollmentManager.getEnrollmentsForNamespace]'s match; both `r`
  /// and `rw` satisfy the ≥`r` bar the discovery verb requires.
  String? _accessForNamespace(EnrollDataStoreValue enVal, String namespace) {
    for (final entry in enVal.namespaces.entries) {
      final ns = entry.key;
      if (ns == EnrollmentConstants.allNamespaces ||
          ns == namespace ||
          namespace.endsWith('.$ns')) {
        return entry.value;
      }
    }
    return null;
  }

  bool _doesEnrollmentHaveManageNamespace(
      EnrollDataStoreValue enrollDataStoreValue) {
    return enrollDataStoreValue.namespaces
        .containsKey(EnrollmentConstants.enrollManageNamespace);
  }

  /// Pending enrollments have to be notified to clients which have rw access
  /// to the __manage namespace, so store a self notification with key
  /// `<enrollmentId>.new.enrollments.__manage` and value containing the
  /// encrypted APKAM symmetric key
  Future<void> _storeNotification(
      String key, EnrollParams enrollParams, String atSign) async {
    AtNotification? atNotification;
    try {
      var notificationValue = {};
      notificationValue[AtConstants.apkamEncryptedSymmetricKey] =
          enrollParams.encryptedAPKAMSymmetricKey;
      // send both encryptedAPKAMSymmetricKey and encryptedApkamSymmetricKey in notification
      // after the server is released, use encryptedAPKAMSymmetricKey. Modify the constant name in at_commons and client side code.
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

  /// Verifies whether the enrollment state matches the intended state.
  /// Throws IllegalStateException: If the enrollment state is different
  /// from the intended state.
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

  /// Checks whether an enrollment with the same appName and deviceName already exists for the given request.
  /// If a matching enrollment is found, [AtEnrollmentException] exception is thrown.
  /// Otherwise, the enrollment request is accepted.
  @visibleForTesting
  Future<void> preventDuplicateEnrollRequest(EnrollParams enrollParams) async {
    // Fetches all the enrollment keys from the keystore.
    List<dynamic> enrollmentKeys = await (await keyStore.getKeys(
            regex: EnrollmentConstants.enrollmentsRegex))
        .toList();

    // Iterate through the existing enrollments and verify that there is no enrollment with the same
    // appName and deviceName combination, and a status of 'pending' or 'approved'
    for (String key in enrollmentKeys) {
      AtData atData = AtData();
      try {
        atData = (await keyStore.get(key))!;
      } on KeyNotFoundException {
        logger.finest('An enrollment with $key does not exist or expired');
      }
      if (atData.data == null) {
        continue;
      }
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue.fromJson(jsonDecode(atData.data!));

      if ((enrollParams.appName == enrollDataStoreValue.appName &&
              enrollParams.deviceName == enrollDataStoreValue.deviceName) &&
          (enrollDataStoreValue.approval?.state ==
                  EnrollmentStatus.approved.name ||
              enrollDataStoreValue.approval?.state ==
                  EnrollmentStatus.pending.name)) {
        String enrollmentId = key.substring(0, key.indexOf('.'));
        throw IllegalStateException(
            'Another enrollment with id $enrollmentId exists with the app name: ${enrollParams.appName} and device name: ${enrollParams.deviceName} in ${enrollDataStoreValue.approval?.state} state');
      }
    }
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

        if (inboundConnection.metaData.authType == AuthType.apkam &&
            (enrollParams.namespaces == null ||
                enrollParams.namespaces!.isEmpty)) {
          // A self-enrollment names its grants explicitly: the child holds
          // exactly what it requests, at most what the parent holds. An
          // empty set would mint an approved credential that can do nothing,
          // which is always a caller bug — refuse it loudly.
          throw IllegalArgumentException(
              'At least one namespace must be specified for an '
              'APKAM-authenticated enroll:request');
        }

        if (enrollParams.otp != null) {
          // encryptedAPKAMSymmetricKey is mandatory for new client enrollments,
          // except when the request advertises a key package. Such a client
          // never generates the symmetric key: the approver mints it and
          // encapsulates it to the advertised public half, so the request has
          // no RSA-wrapped secret to carry. Absence alongside a key package is
          // therefore the signal that conveyance is expected, and the field
          // stays mandatory for every other client so a legacy one still fails
          // here rather than enrolling into a state it cannot decrypt.
          if (enrollParams.encryptedAPKAMSymmetricKey.isNullOrEmpty &&
              enrollParams.metadata?['keyPackage'] == null) {
            throw IllegalArgumentException(
                'encrypted apkam symmetric key is mandatory for new client enroll:request');
          }
          if (enrollParams.namespaces == null ||
              enrollParams.namespaces!.isEmpty) {
            throw IllegalArgumentException(
                'At least one namespace must be specified for new client enroll:request');
          }
        }

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
        // An update that names nothing to change is a caller bug, not a no-op
        // worth accepting: it costs a write and a sync round for nothing, and
        // it usually means the field the caller meant to set is misspelled.
        if (enrollParams.apkamPublicKey == null &&
            enrollParams.signingAlgo == null &&
            enrollParams.apsk == null &&
            enrollParams.metadata == null) {
          throw IllegalArgumentException(
              'enroll:update must name at least one of apkamPublicKey, '
              'signingAlgo, apsk or metadata');
        }
        // Named explicitly rather than silently ignored. These are the two
        // fields the operation must never reach — an enrollment amending
        // itself must not be able to widen its own grant or change its own
        // approval — so a request that asks is told why, not quietly obeyed
        // in part.
        if (enrollParams.namespaces != null) {
          throw IllegalArgumentException(
              'enroll:update cannot change namespaces: an enrollment amending '
              'itself must not be able to widen its own grant');
        }
        break;
      // list / listns carry no enrollParams; listns validates its namespace
      // (from the 'listNamespace' capture group) in its own handler.
    }
  }

  /// Calculates and returns the delay interval in milliseconds for handling
  /// invalid OTP.
  ///
  /// This method updates a series of delays stored in the '_delayForInvalidOTPSeries'
  /// list.
  /// The delays are calculated based on the Fibonacci sequence. If the last delay in the
  /// series surpasses a predefined threshold, the series is reset to default value.
  ///
  /// Returns the calculated delay interval in milliseconds.

  @visibleForTesting
  int getDelayIntervalInMilliseconds() {
    // If the last digit in "delayForInvalidOTPSeries" list reaches the threshold
    // (enrollmentResponseDelayIntervalInMillis) then return the same without
    // further incrementing the delay.
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
    if (authorisedNamespaceAccess == 'rw' ||
        (authorisedNamespaceAccess == 'r' && enrolledNamespaceAccess == 'r')) {
      return true;
    }
    return false;
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
      response) async {
    // Note: The enrollmentId is verified for the null check in the _validateParams methods.
    // Therefore, when control comes here, enrollmentId will not be null.
    EnrollDataStoreValue enVal =
        await enMgr.getEnrollmentById(enrollParams!.enrollmentId!);
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
