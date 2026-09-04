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

  /// Defaulting the initial delay to 1000 milliseconds (1 second).
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
  ///
  /// One bound on the whole record rather than one per opaque field: a
  /// per-field cap bounds nothing while a sibling field is uncapped, and a
  /// field added later is covered without anyone remembering to cap it.
  ///
  /// The record's contents are opaque, so a bound is all the server can
  /// impose. What it protects is not disk: the record is read on every verb
  /// command and held in [EnrollmentManager]'s cache, evicted only on write,
  /// so an oversized record occupies memory for the process's life, and it is
  /// returned whole by `enroll:list` and its `metadata` by `enroll:listns`,
  /// inflating every discovery response for every caller.
  ///
  /// 500KB is far above any legitimate record (ML-DSA-65's public half, the
  /// largest key in play, is ~2.6KB base64-encoded) and far below the ~10MB an
  /// inbound connection will buffer, which is otherwise the only ceiling on a
  /// request reaching this path with nothing but an OTP.
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
    // Approve, deny, revoke or list enrollments only on authenticated connections
    if (operation != 'request' && !atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException(
          'Cannot $operation enrollment without authentication');
    }
    EnrollParams? enrollVerbParams;

    // Ensure that enrollParams are present for all enroll operation.
    // 'list', 'listns' and 'infons' carry no enrollParams JSON body; the
    // namespace-scoped pair take their argument in the command itself.
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
      // Folded here, once, to EXACTLY the keystore's fold. The keystore
      // normalises every key that way, so a non-canonical spelling resolves
      // to the SAME record while comparing unequal to the id on the
      // connection. Every id comparison on the revoke path is a string
      // comparison against this value, so an unfolded id makes each of them
      // silently vacuous while the record is still written revoked. The
      // last-root refusal is the worst of them, since it excludes the act's
      // own targets by KEY and a key built from an unfolded id excludes
      // nothing.
      //
      // A consequence worth naming: a non-canonical spelling now behaves
      // exactly like the canonical one everywhere, `enroll:fetch` of one's own
      // enrollment and a self-`enroll:update` included. An id of nothing but
      // whitespace folds to empty and _validateParams refuses it as missing.
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
          // this call flipped: on a retry after a part-way failure the flipped
          // set is empty for precisely the descendants whose open connections
          // still need dropping.
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

    // enroll:fetch returns the enrollment's encryptedAPKAMSymmetricKey, a
    // secret. A caller may always fetch its OWN enrollment, and a connection
    // carrying no enrollment id may fetch any. Fetching ANOTHER enrollment
    // requires __manage AND access to EVERY namespace the target holds, the
    // same bar as approve/deny/revoke.
    //
    // "EVERY namespace" includes __manage itself, so a '__manage:r'
    // administrator cannot fetch a '__manage:rw' enrollment. That is a
    // statement about authority over the target, not about the secrecy of the
    // field: enroll:list redacts by the caller's own __manage letter, so this
    // gate is not what keeps that value from a read-only administrator.
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final callerEnrollmentId = inboundConnectionMetadata.enrollmentId;
    if (!AbstractVerbHandler.isCramConnection(inboundConnectionMetadata) &&
        callerEnrollmentId != targetEnrollmentId) {
      // The remedy names connections carrying no enrollment id rather than
      // "an owner", because that is what this gate is keyed on.
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

    // `expiresAt` is the effective expiry, read from the record's metadata:
    // it lives nowhere in the value's own JSON, and a client has no other way
    // to learn it.
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
  /// A CRAM connection's request is auto-approved with `__manage:rw` and
  /// `*:rw`; a connection already carrying an enrollment retrofits itself;
  /// any other connection must present a valid OTP and lands `pending`.
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

    // Structural checks plus a size pre-filter, before an OTP is spent. The
    // record itself is bounded at each write.
    _validateEnrollParams(enrollParams);

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

    // The throttle and OTP gate stay OUTSIDE the section: neither touches an
    // enrollment, and the invalid-OTP arm sleeps for a growing interval, so
    // holding the atSign's one enrollment-mutation lock across it would let a
    // stream of wrong passcodes stall every approve and revoke.
    //
    // Inside is the read-decide-write half. A retrofit reads its predecessor,
    // checks it is approved and mints a successor carrying its grants, so a
    // revoke landing mid-decision would otherwise be answered by a fresh,
    // approved credential holding what the revoke was taking away.
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
      // A CRAM-authenticated connection is allowed a duplicate enrollment
      // request.
      logger.warning('CRAM-authenticated connection - i.e. initial enrollment;'
          ' will replace the existing initial enrollment, if any');
    } else if (carriesEnrollment(inboundConnectionMetadata)) {
      // A self-enrollment keeps its app's own (appName, deviceName): a
      // retrofit is the same app re-enrolling itself, and sibling clones of
      // one keyfile share those names. Uniqueness among live enrollments ends
      // on this branch by design, keyed on the enrollment the connection
      // carries exactly as the retrofit branch below is.
    } else {
      // Every other connection must not duplicate an existing enrollment's
      // (appName, deviceName).
      await preventDuplicateEnrollRequest(enrollParams);
    }
    // Every path that installs key material. AFTER the (appName, deviceName)
    // rule, so a request breaking both is told about the one it can fix by
    // renaming, and BEFORE anything is written, so a refusal persists nothing.
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

    // The key package (at `metadata.keyPackage`), `signingAlgo` and the
    // client-composed `_apsk` ride EnrollParams on enroll:request and are
    // persisted verbatim; there is no separate metadata write.
    if (enrollParams.metadata != null) {
      enrollmentValue.metadata = enrollParams.metadata;
    }
    if (enrollParams.signingAlgo != null) {
      enrollmentValue.signingAlgo = enrollParams.signingAlgo;
    }
    // At most one of the two is set: _validateEnrollParams refused a request
    // carrying both.
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

    // Auto-approve a request from a CRAM-authenticated connection.
    if (AbstractVerbHandler.isCramConnection(atConnection.metaData as InboundConnectionMetadata)) {
      enrollNamespaces[EnrollmentConstants.enrollManageNamespace] = 'rw';
      enrollNamespaces[EnrollmentConstants.allNamespaces] = 'rw';
      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      responseJson['status'] = 'approved';
      final inboundConnectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      inboundConnectionMetadata.enrollmentId = newEnrollmentId;
      // Before any write, so a refusal leaves no published _apsk behind for
      // an enrollment that was never created.
      _validateRecordSize(enrollmentValue);

      // ⛔ This branch must NOT copy the APKAM public key into
      // `at_pkam_publickey`. That key is the credential LEGACY PKAM
      // authenticates against, which by definition supplies no enrollment id,
      // while an `enroll:request` mints an APKAM credential that always
      // authenticates WITH one. Copying gives one keypair two identities with
      // separate lifecycles, so revoking the enrollment leaves the key
      // authenticating over the legacy path. The write is also
      // unconditional, so each repeat of this deliberately repeatable request
      // destroys any legacy credential the atSign already had.
      //
      // A flat key an older server left behind is dealt with at startup,
      // before any client connects. See
      // [EnrollmentManager.migrateFlatKeyAtStartup].

      // Publish the client-composed `_apsk` signing key, if it sent one.
      await _publishApskSigningKey(
          newEnrollmentId, enrollmentValue, currentAtSign);
      AtData enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());

      await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.approved);
      return;
    }

    // A connection already holding an enrollment retrofits itself: it enrols
    // a FRESH enrollment that REPLACES the one it authenticated as,
    // auto-approved with no human step and no OTP, on the authority of that
    // existing approved enrollment. Because the successor replaces rather
    // than descends, it holds exactly the predecessor's grants. The
    // predecessor is capped rather than removed, and only once the successor
    // has authenticated, so sibling clones of one keyfile can still retrofit
    // until the cap elapses. That is what retrofit is FOR: splitting a shared
    // keyfile into per-device credentials.
    //
    // ⚠️ Keyed on the enrollment carried rather than on the auth type, and
    // placed AFTER the CRAM auto-approve deliberately. A CRAM connection
    // carries the id it has just minted, so an id-keyed gate ahead of the
    // auto-approve would capture that connection's next request as a
    // retrofit, and at_auth throws unless a first enrollment comes back
    // `approved`, breaking onboarding for every new user.
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
      // A retrofit is a ONCE-OFF: one no-approver migration per device, not a
      // series. Each link would restart the key-expiry clock, so an
      // enrollment with a one-hour term could renew itself indefinitely, and
      // each adds a record whose loss severs the revocation cascade behind it.
      if (predecessor.retrofitPredecessorEnrollmentId != null) {
        throw UnAuthorizedException(
            'Enrollment $predecessorId is itself a replacement, and a '
            'replacement may not be replaced without an approver');
      }
      // Escalation first, so a request naming MORE than the predecessor holds
      // keeps its own diagnosis rather than reading as a mismatch.
      verifyNoEscalation(predecessor.namespaces, enrollNamespaces);
      requireGrantsMatchPredecessor(predecessor.namespaces, enrollParams.namespaces);
      enrollmentValue.namespaces = Map.of(predecessor.namespaces);

      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      // What this successor REPLACED, which is what the retrofit cap reads to
      // know whose expiry to put a clock on.
      //
      // ⛔ Not for revocation: the revoke path does NOT walk this edge. A
      // retrofit produces a peer, so revoking a superseded credential must not
      // take the one that superseded it. A successor is reached through the
      // approver it INHERITS, on the line below.
      enrollmentValue.retrofitPredecessorEnrollmentId = predecessorId;
      // A retrofit produces a PEER, not a child, so it takes the
      // predecessor's place in the approval graph as well as its grants.
      // Leaving this null would make a retrofit an escape hatch from the
      // cascade: revoking the approver would reach the predecessor and stop
      // while its successor went on authenticating.
      enrollmentValue.parentEnrollmentId =
          predecessor.parentEnrollmentId;
      // Time is a separate axis from grants: the successor carries the
      // predecessor's grants exactly, but may hold a shorter life.
      if (enrollParams.apkamKeysExpiryDuration == null) {
        enrollmentValue.apkamKeysExpiryDuration =
            predecessor.apkamKeysExpiryDuration;
      }
      // A stated posture may narrow the predecessor's, never widen it. TIME
      // is the axis `verifyNoEscalation` does not cover, and this is the one
      // enrollment path with no human in the loop to notice. Zero is the
      // keystore's "never expires" and a negative value skips the ttl write
      // altogether, so both ask for a permanent credential; against a
      // time-bound predecessor neither is honoured.
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

      // The clamp above compares TERMS, and a term restarts its clock at THIS
      // write while the predecessor's is already running, so an equal term
      // expires later in absolute time by exactly the predecessor's age. It is
      // also vacuous where it matters most: it reads the posture off the
      // predecessor's VALUE, while a capped predecessor's real deadline lives
      // only in its RECORD metadata. So bound the successor by that stored
      // DEADLINE.
      //
      // The POSTURE is narrowed rather than the ttl written below, because
      // `retrofitCapTtlMillis` takes the LATER of the stored expiry and
      // `createdAt + term`: a full-length term left on the record would let
      // the successor's own first cap recompute straight past this bound.
      DateTime? boundedDeadline;
      final DateTime? predecessorExpiresAt =
          (await keyStore.getMeta(enMgr.buildEnrollmentKey(predecessorId)))
              ?.expiresAt
              ?.toUtc();
      if (predecessorExpiresAt != null) {
        final int remainingMs = predecessorExpiresAt
            .difference(DateTime.now().toUtc())
            .inMilliseconds;
        // Zero is the keystore's "never expires", so a spent predecessor must
        // not round its successor up to immortal.
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
          // Carried to the write as an ABSOLUTE: a ttl is re-anchored at the
          // instant of the write, so writing the bound as a duration would
          // land past it by the intervening work.
          boundedDeadline = predecessorExpiresAt;
        }
      }
      // May be absent: a PQ self-enrollment conveys its legacy material
      // client-side, sealed to its own new key package.
      enrollmentValue.encryptedAPKAMSymmetricKey =
          enrollParams.encryptedAPKAMSymmetricKey;
      responseJson['status'] = 'approved';

      // Before any write, so a refusal leaves no published _apsk behind for an
      // enrollment that was never created.
      _validateRecordSize(enrollmentValue);
      // Publish the client-composed `_apsk` signing key, if it sent one.
      await _publishApskSigningKey(
          newEnrollmentId, enrollmentValue, currentAtSign);
      // The successor's record expires per its inherited or stated posture,
      // exactly as the ordinary approve path writes it. A ttl of zero is the
      // keystore's "never expires", matching a predecessor with no posture.
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

      // The predecessor is NOT capped here. Storing the successor proves only
      // that this server wrote a record, while its APKAM private half is
      // persisted client-side, so a failed keyfile write would leave the
      // successor existing here and nowhere else with a clock already running
      // on the only credential that still works. The cap is armed by the
      // successor's FIRST PKAM authentication instead. See
      // [EnrollmentManager.armRetrofitCapOnFirstAuth].
      return;
    }

    // A standard enrollment request: notify an approver app, and store the
    // enrollment `pending`.
    enrollmentValue.encryptedAPKAMSymmetricKey =
        enrollParams.encryptedAPKAMSymmetricKey;
    enrollmentValue.approval = EnrollApproval(EnrollmentStatus.pending.name);
    responseJson['status'] = 'pending';
    // Every check runs before the notification: an approver must not be told
    // about a request that was refused and never stored.
    _validateRecordSize(enrollmentValue);
    await _storeNotification(enrollmentKey, enrollParams, currentAtSign);
    AtData enrollData = AtData()
      ..data = jsonEncode(enrollmentValue.toJson())
      // A pending enrollment expires after the configured limit, beyond which
      // approve, deny and revoke are all refused.
      ..metaData = (AtMetaData()..ttl = enrollmentExpiryInMills);

    await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.pending);
  }

  /// Rejects any requested grant the predecessor enrollment does not hold.
  ///
  /// Subset per namespace and per access letter: `r` fits under `rw`, never
  /// the reverse. A predecessor's `*` grant covers any ordinary namespace at
  /// the letters it carries, mirroring the server's own authorisation, but
  /// `__manage` and `*` themselves must be held literally, because `*` does
  /// not imply `__manage` anywhere else in the server.
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
  /// A retrofit REPLACES its predecessor rather than descending from it, so
  /// [requested] is optional: omit it and the predecessor's grants are
  /// inherited, state it and it must name exactly them.
  ///
  /// Refused rather than reconciled in both directions. Widening a narrower
  /// request would hand a caller authority it never asked for; honouring one
  /// would retire a working credential for a successor that cannot do what it
  /// replaced, a loss surfacing far from the request that caused it.
  ///
  /// [verifyNoEscalation] rejects escalation before this and keeps its own
  /// diagnosis, so what reaches the throw here is anything that is not
  /// literally the predecessor's map. That includes a request naming MORE
  /// namespaces without escalating, as `{'*':'rw','wavi':'rw'}` does against
  /// `{'*':'rw'}`.
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
  /// Returns every id the revoke INTENDED to revoke by cascade, so the caller
  /// can drop their connections. Deliberately not the subset this call
  /// flipped: a retry after a part-way failure finds the descendants already
  /// revoked, so the flipped set is empty for exactly the enrollments whose
  /// connections still need dropping. The response field reports the flipped
  /// set, which answers a different question. Empty for every operation but
  /// `revoke`, and for a revoke whose target has no descendants.
  Future<List<String>> _handleApproveDenyRevokeUnrevoke(
      EnrollmentManager enMgr,
      InboundConnectionMetadata inboundConnectionMetadata,
      EnrollParams enrollParams,
      currentAtSign,
      String operation,
      Map<dynamic, dynamic> responseJson,
      Response response) async {
    // Read-decide-write across the whole store, so it runs as this atSign's
    // only in-flight enrollment mutation. The SPAN is the point rather than
    // the write: a revoke reads the target, walks its descendants and asks
    // whether any unexpiring root survives the act before writing, and two of
    // those at once each count the root the other is about to remove, leaving
    // the atSign with none. Serialising the writes alone would not fix that.
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
      // The enrollment key is expired or invalid.
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

    // A target holding NO namespaces passes the loop below vacuously (zero
    // iterations, no refusal), and the `__manage` requirement lives inside
    // that loop, so it is not asked either. Gated on caller-vs-target the way
    // delete is: a connection carrying no enrollment id must still be able to
    // act on such a record, or the most anomalous enrollment on the atSign
    // becomes the one nothing can clear up, and the self clause keeps a forced
    // self-revoke working.
    final String? callerIdForAuthz = inboundConnectionMetadata.enrollmentId;
    if (callerIdForAuthz != null &&
        callerIdForAuthz.isNotEmpty &&
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

      // A revoker must survive its own act. The authorisation loop above only
      // asks whether the caller covers the target's namespaces, so an
      // enrollment the target admitted passes that check against the very
      // enrollment that admitted it while being a descendant of it, and the
      // cascade would take the caller with it. On a two-enrollment atSign that
      // strands it without anyone self-revoking, which is why neither the
      // self-revoke refusal nor the liveness check below sees it.
      if (callerId != null && cascadeIds.contains(callerId)) {
        throw AtEnrollmentRevokeException(
            'Cannot revoke enrollment $enId: $callerId, the enrollment making '
            'this request, descends from it by approval and would be revoked '
            'by the same cascade. Revoke $enId from an enrollment outside the '
            'chain of approvals beneath it');
      }

      // Revoking a fully privileged enrollment may not leave the atSign
      // without one. Asked for EVERY such revoke, not only a self-revoke: a
      // root with a finite lifetime can revoke the atSign's other root and
      // then expire, which strands it just as completely and trips none of the
      // other refusals.
      //
      // The survivor has to be PERMANENT. A root with a finite life only
      // defers the question, with nothing at the time of the revoke to say so.
      // A non-root caller is never counted whatever its lifetime, because
      // restoring a root means APPROVING one and approving is checked per
      // namespace against what the approver holds, so only a root can admit a
      // root.
      //
      // Asked over what SURVIVES the cascade rather than over what is stored:
      // the descendants are still `approved` while this runs, so counting them
      // would report the atSign safe at the moment it is stranded.
      //
      // Asked of the ACT, not of the target, and both halves are load-bearing.
      // The command names only the top of the subtree it removes, so a target
      // holding no full privilege may still carry one away in its cascade, and
      // a guard reading the target's grants alone lets the last root go
      // silently. The target is asked about because its own cascade cannot
      // contain it.
      //
      // Both halves ask `EnrollmentManager.isUsableRootEnrollment` rather than
      // reading the grants, so a record with no credential recorded for it is
      // not counted as a root taken away.
      //
      // Skipped for a connection carrying no enrollment id, which can always
      // mint a fresh enrollment, so no act of its can leave the atSign unable
      // to approve a replacement.
      if (callerId != null) {
        // Cheapest question first: this reads one record per enrollment the
        // act removes, while the liveness question walks the whole keystore.
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

    // The cascade goes FIRST, before the target's own write, because of what
    // a retry does. Revoking the target first and then failing part-way
    // through the subtree leaves the same command answering "Cannot revoke a
    // revoked enrollment", so the cascade can never be completed. This order
    // fails the other way and re-running finishes the job.
    //
    // One moment for the whole command, the named enrollment and every
    // enrollment the cascade takes. See [EnrollmentManager.revokeAll].
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

    // The revocation history for the enrollment this command NAMED; the
    // cascade wrote its own above with `cascadedFrom` pointing here. Grants
    // are read off the record BEFORE the write, and recorded on the un-revoke
    // too: an event has to name the namespaces it affects without the
    // enrollment, which by then may be reaped.
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
    // A revoke records BEFORE its write and an un-revoke AFTER it, so a crash
    // in the window errs towards reporting the namespace as revoked.
    // Over-stating costs a client a refetch; under-stating tells it nothing
    // has changed when a credential has just stopped working.
    if (operation == 'revoke') {
      await enMgr.recordRevocationEvents([revocationEvent!]);
    }

    // Record WHO approved, so a later revocation of the approver takes the
    // enrollments it admitted with it. Read off the connection rather than the
    // request, so an approver cannot name someone else as the admitting party;
    // null over a connection carrying no enrollment id, there being nothing
    // there to revoke later.
    if (operation == 'approve') {
      final String? approverId = inboundConnectionMetadata.enrollmentId;
      enVal.parentEnrollmentId =
          (approverId != null && approverId.isNotEmpty) ? approverId : null;
    }

    AtData atData = AtData()..data = jsonEncode(enVal.toJson());
    // Approval resets the ttl off the enrollment's APKAM key-expiry posture,
    // replacing the window the request had to be approved in.
    //
    // A non-positive posture asks for a credential that does not expire and is
    // written as ttl 0, the keystore's "never expires", rather than passed
    // through. A NEGATIVE ttl is not "no expiry": the metadata builder derives
    // `expiresAt` only for `ttl >= 0`, so a negative one leaves the PENDING
    // record's expiry standing on the approved enrollment, and a later
    // retrofit cap measured against that stale value appears to EXTEND the
    // enrollment rather than shorten it.
    if (operation == 'approve') {
      String ek = enMgr.buildEnrollmentKey(enId);
      AtMetaData emd = await keyStore.getMeta(ek) ?? AtMetaData();
      final int postureMs = enVal.apkamKeysExpiryDuration.inMilliseconds;
      emd.ttl = postureMs > 0 ? postureMs : 0;
      atData.metaData = emd;
    }
    // A write that says nothing about expiry must not MOVE expiry. The
    // metadata builder re-derives `expiresAt = now + ttl` from the RETAINED
    // ttl on any write that does not assert the stored absolute back, so a
    // revoke, deny or unrevoke would silently restart the APKAM key-expiry
    // clock and any retrofit cap standing on the record. `approve` is the
    // deliberate exception: it starts that clock, just above.
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
      // Read off the RECORD, not off these approve params: the value is the
      // enrollee's, and an approver must not be able to substitute a signing
      // key for the enrollment it is approving.
      await _publishApskSigningKey(enId, enVal, currentAtSign);
    }
    responseJson['enrollmentId'] = enId;
    // Emitted only when a cascade happened, so no existing response shape
    // changes.
    if (cascaded.isNotEmpty) {
      responseJson['cascadedEnrollmentIds'] = cascaded;
    }
    return cascadeIds;
  }

  /// Refuses an operation that would make [enId] active while the enrollment
  /// that APPROVED it is not.
  ///
  /// This is what stops the revoke cascade being one-way: `enroll:unrevoke` on
  /// an enrollment the cascade swept up would otherwise resurrect exactly the
  /// orphan it removed. It follows the approval edge and not the replacement
  /// one, revoking an enrollment not revoking what replaced it.
  ///
  /// `unrevoke` is the transition this governs. `approve` is checked too, so
  /// the rule reads the same at every transition into an active state, but
  /// that arm cannot fire as the code stands: a pending record carries no
  /// approver, and the approver is recorded further down this same operation,
  /// after the gate has run.
  ///
  /// Two things are always allowed, for DIFFERENT reasons. A null
  /// [EnrollDataStoreValue.parentEnrollmentId] means nothing recorded here
  /// admitted it, and that check alone is what stops the rule barring every
  /// enrollment an owner ever admitted. An approver that no longer EXISTS is
  /// separate and narrower: it is permitted because there is nothing left to
  /// compare against, which does mean `enroll:delete` on an approver is a way
  /// to un-revoke what it admitted, the same gap
  /// [EnrollmentManager.descendantsOf] documents for a deleted link.
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
  /// nothing else. `namespaces` and the approval state are permanently out of
  /// reach: this operation is self-only, so an enrollment that could reach
  /// them could widen its own grant, which is privilege escalation with a
  /// valid signature on it.
  ///
  /// Replacing `apkamPublicKey` is how an enrollment rotates its
  /// authentication keypair while keeping its id, so records addressed to that
  /// id are not stranded.
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

    // Self-only, and an explicit exception to `isAuthorized`'s "no
    // enrollmentId means full permissions" default: a connection carrying none
    // is refused here rather than waved through. It cannot sign with this
    // enrollment's APKAM private half, so anything it wrote would fail every
    // reader's verification and buys only a denial of service. Self-only is
    // also what makes replace semantics safe, the only party who can reinstate
    // a stale value being the holder of the key it was signed with.
    if (connectionMetadata.enrollmentId != enId) {
      // The remedy is value-INDEPENDENT: no branch on which identity the
      // connection happens to carry, so the refusal path stays free of a
      // conditional a test pinning the message would pin too.
      throw AtEnrollmentException(
          'enroll:update is self-only: this connection is authenticated as '
          '${connectionMetadata.enrollmentId ?? "the owner"}, not $enId. '
          'Authenticate as $enId to update it');
    }

    // As for approve/deny/revoke/unrevoke: the identity checks above decide
    // from the connection and the id alone; everything below reads the record,
    // decides against it and writes it back.
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

    // The same checks as enroll:request, applied before anything is written.
    _validateEnrollParams(enrollParams);

    if (enrollParams.apkamPublicKey != null) {
      final newSigningAlgo = enrollParams.signingAlgo ?? enVal.signingAlgo;
      await _verifyApkamPublicKeyPossession(
        enrollmentId: enId,
        apkamPublicKey: enrollParams.apkamPublicKey!,
        signingAlgo: newSigningAlgo,
        signature: enrollParams.apkamPublicKeySignature,
      );
      // A rotation installs key material like any request does; the record
      // re-sending its own current key is not a collision with itself.
      await _refuseKeyHeldByAnotherEnrollment(
          enrollParams.apkamPublicKey!, newSigningAlgo,
          excluding: enId);
      enVal.apkamPublicKey = enrollParams.apkamPublicKey!;
      if (enrollParams.signingAlgo != null) {
        enVal.signingAlgo = enrollParams.signingAlgo;
      }
    } else if (enrollParams.signingAlgo != null) {
      // The algorithm describes the key, so moving one without the other
      // leaves the record claiming a spelling its key is not in, and PKAM
      // verification is record-authoritative.
      throw IllegalArgumentException(
          'signingAlgo cannot be changed without apkamPublicKey: the '
          'algorithm describes the key');
    }

    // Setting either shape clears the other: one record publishes one value,
    // and this is the operation that moves an enrollment between them.
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

    // Measured AFTER the merge: metadata merges rather than replaces, so a
    // request nowhere near the cap can still push the record past it.
    _validateRecordSize(enVal);

    // An untouched ttl is not an untouched EXPIRY. The metadata builder
    // re-derives `expiresAt = now + ttl` on any write that does not assert the
    // stored absolute back, so without the carry below an enrollment could
    // postpone its own retirement indefinitely by amending itself, one
    // `enroll:update` per grace period, and the retrofit cap would be advisory
    // rather than a deadline.
    //
    // The status is read off the record JUST BEFORE the write, never off the
    // snapshot at the top of this method: an APKAM signature verification is
    // awaited between the two, and a revoke landing in that window would
    // otherwise be UNDONE, since `put` moves an enrollment's per-enrollment
    // data to match the status it is handed and writing `approved` back would
    // return the revoked enrollment's published `_apsk` to the live address.
    //
    // It REFUSES rather than adjusting the status handed to `put`, because
    // `_publishApskSigningKey` below writes to the approved address without
    // going through `put` at all. Nothing is written once the record is no
    // longer approved.
    //
    // `getMeta` is `(await get(key))?.metaData`, so reading the whole record
    // here costs nothing the discarded read did not.
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

    // Republish only when the request carried a new value; an update naming
    // neither shape leaves the published record exactly as it was.
    if (enrollParams.apsk != null || enrollParams.apskLegacy != null) {
      await _publishApskSigningKey(enId, enVal, currentAtSign);
    }

    responseJson['enrollmentId'] = enId;
    // The status just read off the record, not a constant, so it cannot
    // disagree with what is on disk.
    responseJson['status'] = current.name;
  }

  /// Verifies that whoever sent this `enroll:update` holds the private half of
  /// the [apkamPublicKey] it is asking to install.
  ///
  /// The connection proves possession of the enrollment's **current** key and
  /// nothing else proves possession of the new one, so without this check a
  /// compromised-but-authenticated client can install a public key whose
  /// private half is held by an attacker, locking out the legitimate holder
  /// while the record still looks valid.
  ///
  /// The signature covers `<enrollmentId>|<apkamPublicKey>|<signingAlgo>` and
  /// is verified against the new public key carried in the same request: a
  /// self-signature, which is what proof of possession is.
  ///
  /// No nonce, deliberately. The operation is self-only over an authenticated
  /// connection and the old key stops authenticating the moment the rotation
  /// lands, so a replayed request can only be sent by the current holder,
  /// making a rollback self-harm rather than an attack.
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

    // ApkamSignatureVerifier is the same path `pkam:` uses, and the two must
    // agree byte-for-byte about how a signature is framed: a key installed
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
  /// self encryption key against the enrollment's `__manage` keys. They stay
  /// on the server, never syncing to a client, and an approving app reads them
  /// to convey the keys to a new enrolling app.
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
  /// Both shapes at once is a client error rather than a precedence question:
  /// one record publishes one value, and silently preferring one would publish
  /// a signing key the enrollee did not think it had asked for.
  ///
  /// The size check here is a **pre-filter**, not the authority. It runs
  /// before the OTP is validated so an oversized request does not spend a
  /// one-shot passcode on its way to being refused, which is safe because
  /// these params encode larger than the part of the record they become.
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
  /// after any merge, that being the only measurement the bound can be stated
  /// in. Refused rather than truncated: a truncated record is unparseable.
  ///
  /// `enroll:update` is where this does the work. `metadata` merges rather
  /// than replaces, so a request nowhere near the cap can still leave a record
  /// past it, and no measurement of the request can see that.
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
  /// The two shapes are stored differently because they are read differently.
  /// [EnrollDataStoreValue.apskLegacy] goes out **verbatim**, an `_apsk`
  /// consumer base64-decoding the value as an RSA key for which a JSON string
  /// is not what the parser reads. [EnrollDataStoreValue.apsk] is JSON-encoded,
  /// which makes it unmistakable to those same consumers: they fail loudly on
  /// it rather than mis-reading it.
  ///
  /// The two are mutually exclusive, so the order here decides nothing.
  static String? _apskRecordValue(EnrollDataStoreValue enVal) {
    if (enVal.apskLegacy != null) {
      return enVal.apskLegacy;
    }
    if (enVal.apsk != null) {
      return jsonEncode(enVal.apsk);
    }
    return null;
  }

  /// Publishes the `_apsk` value the CLIENT composed and sent on
  /// `enroll:request` at `public:_apsk.<enrollmentId>.a.__e@<atSign>`, the
  /// location the at_client `ApkamSigning` mixin reads.
  ///
  /// A no-op when [enVal] carries neither shape. The atServer composes
  /// nothing: PKAM verification reads the record's `apkamPublicKey` and
  /// `signingAlgo`, so `_apsk` is a client-side artefact whose format belongs
  /// to the side that parses it.
  ///
  /// The server writes it despite never reading it because the per-enrollment
  /// namespace it lands in admits writes only from that enrollment, and at
  /// approval that connection has never existed, while the approver needs the
  /// record immediately to verify the enrollee's key package against it.
  ///
  /// Takes the RECORD rather than a value, so every call site publishes what
  /// the enrollee asked for and an approver cannot substitute its own.
  ///
  /// World-readable, so a same-atSign or peer-atSign verifier can reach it via
  /// plookup. Idempotent.
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
      // An un-revoked enrollment goes back to approved so its APKAM keys
      // authenticate again.
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
    // A CRAM connection holds the atSign itself rather than a delegated share
    // of it, so it gets every enrollment whole: there is no secret here it
    // could not read straight out of the keystore.
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

    // An APKAM connection sees every enrollment when its own holds `__manage`,
    // and otherwise only its own record.
    EnrollDataStoreValue enrollDataStoreValue =
        await enMgr.getEnrollmentById(authenticatedEnrollmentId);

    if (_doesEnrollmentHaveManageNamespace(enrollDataStoreValue)) {
      // Which projection is decided by the caller's own __manage LETTER, not
      // merely by whether it holds the namespace. The record carries
      // `encryptedAPKAMSymmetricKey`, the wrapped key an approver needs to
      // admit an enrollment, and a read-only administrator can never approve,
      // so it gets the roster projection: which enrollments exist, what each
      // holds and what state each is in.
      //
      // enroll:fetch asks a different question of the same data, authority
      // over one named TARGET, and keeps its own gate.
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
        // The caller's OWN record, whole: this enrollment's own key material,
        // which the client holding it already has.
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
  ///
  /// Only enrollments with at least read access to [namespace] are included,
  /// and the caller must be APKAM-authenticated, approved, and hold at least
  /// read access to the namespace itself.
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
  /// A MAP, and deliberately so. The last revocation affecting a namespace is
  /// not a fact about any roster member, and a map has room for the next
  /// per-namespace fact without touching the roster's shape, which clients
  /// decode as a list.
  ///
  /// `lastRevokedAt` is present ALWAYS, null when nothing holding the
  /// namespace has been revoked: an absent key and a key a client failed to
  /// parse are the same thing to a careless reader, while an explicit null is
  /// an answer.
  ///
  /// Derived from the revocation history, which outlives the enrollments it
  /// describes, and it NETS OUT un-revocations, so it can move BACKWARDS. A
  /// client deciding whether to refetch must compare it for inequality rather
  /// than order it.
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
  ///
  /// Shared rather than restated so the two verbs cannot drift apart: what a
  /// caller may learn ABOUT a namespace and who it may learn holds that
  /// namespace are the same authorisation question.
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
    // `*` does not imply `__manage` anywhere else in the server and must not
    // here. The matcher above falls back to the wildcard for any namespace it
    // holds no explicit grant on, `__manage` included, so without this a
    // caller holding `*` and no `__manage` reaches the `__manage` roster and
    // its revocation history.
    if (namespace == EnrollmentConstants.enrollManageNamespace &&
        !_doesEnrollmentHaveManageNamespace(callerEnVal)) {
      throw UnAuthorizedException(
          'Caller enrollment is not authorised for namespace "$namespace":'
          ' it must be held explicitly, and a `*` grant does not confer it');
    }
  }

  /// Whether the enrollment holds `__manage` EXPLICITLY. A `*` grant does not
  /// satisfy this: the wildcard must not launder the namespace that governs
  /// enrollments.
  bool _doesEnrollmentHaveManageNamespace(
      EnrollDataStoreValue enrollDataStoreValue) {
    return enrollDataStoreValue.namespaces
        .containsKey(EnrollmentConstants.enrollManageNamespace);
  }

  /// Announces a pending enrollment to approver apps as a self notification
  /// keyed `<enrollmentId>.new.enrollments.__manage`, carrying the encrypted
  /// APKAM symmetric key. Delivery is gated by the monitor path's ordinary
  /// authorisation, so it reaches connections holding `__manage` explicitly.
  Future<void> _storeNotification(
      String key, EnrollParams enrollParams, String atSign) async {
    AtNotification? atNotification;
    try {
      var notificationValue = {};
      notificationValue[AtConstants.apkamEncryptedSymmetricKey] =
          enrollParams.encryptedAPKAMSymmetricKey;
      // Both spellings go out: the at_commons constant and the name clients
      // read. Dropping either is a wire change that has to sweep both sides.
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
  /// non-empty enrollment id, which names the record a self-enrollment
  /// replaces. This, and not the auth type, selects the retrofit branch of the
  /// request path, the (appName, deviceName) skip that goes with it, and the
  /// mandatory-namespace exemption in `_validateParams`. Whether that
  /// enrollment is APPROVED is checked by the branch, which reads the record.
  ///
  /// Authentication is part of it because an id is only ever put on a
  /// connection by the authentication that admitted it.
  @visibleForTesting
  static bool carriesEnrollment(InboundConnectionMetadata md) {
    final String? id = md.enrollmentId;
    return md.isAuthenticated && id != null && id.isNotEmpty;
  }

  /// Refuses a request whose (appName, deviceName) an approved or pending
  /// enrollment already holds, with [IllegalStateException].
  ///
  /// Read off the stored roster rather than the visible one, the same walk
  /// [_refuseKeyHeldByAnotherEnrollment] makes: an elapsed-but-unswept record
  /// reports its state as `expired` there, so it holds nothing here either.
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
  /// One keypair under two names is two identities with separate lifecycles:
  /// revoking one leaves the key authenticating as the other. So a revoked or
  /// denied holder blocks re-enrolment with the same keypair until it is
  /// deleted, and an expired record blocks until the sweep removes it.
  /// [excluding] is the enrollment re-sending its own current key.
  ///
  /// The refusal names the holding enrollment only under `testingMode`, as a
  /// diagnostic for the rigs: an unauthenticated requester has no claim to
  /// read the roster, and an authenticated one can list it.
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
          // Mandatory for a new client enrollment, except when the request
          // advertises a key package: such a client never generates the
          // symmetric key, the approver minting it and encapsulating it to the
          // advertised public half, so there is no RSA-wrapped secret to
          // carry. The field stays mandatory for every other client, so a
          // legacy one fails here rather than enrolling into a state it cannot
          // decrypt.
          if (enrollParams.encryptedAPKAMSymmetricKey.isNullOrEmpty &&
              enrollParams.metadata?['keyPackage'] == null) {
            throw IllegalArgumentException(
                'encrypted apkam symmetric key is mandatory for new client enroll:request');
          }
        }

        // Outside the OTP branch deliberately. A request naming no namespaces
        // is meaningful only on the two paths that fill them in on its behalf:
        // CRAM, which grants `__manage` and `*`, and a retrofit, which
        // inherits its predecessor's exactly. Every other path writes the
        // grants the request chose, so an empty map lands an enrollment no
        // caller can ever demonstrate authority over, the per-namespace
        // authorisation loops iterating the TARGET's grants and passing with
        // zero iterations.
        //
        // ⚠️ The exemption must be keyed exactly as the request path's
        // branches are: CRAM by auth type, the retrofit by the enrollment the
        // connection carries. Keying the two differently is how an
        // empty-grant record gets minted.
        final InboundConnectionMetadata md =
            inboundConnection.metaData as InboundConnectionMetadata;
        if (!AbstractVerbHandler.isCramConnection(md) &&
            !carriesEnrollment(md) &&
            (enrollParams.namespaces == null ||
                enrollParams.namespaces!.isEmpty)) {
          throw IllegalArgumentException(
              'At least one namespace must be specified for enroll:request');
        }

        // The access level is client-supplied JSON stored verbatim and then
        // read by every authorisation decision on the atSign, so this is the
        // one place a spelling the server does not act on can be kept out of
        // the store. See [EnrollmentAccess].
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
        // An update naming nothing to change is a caller bug rather than a
        // no-op worth accepting: it usually means a misspelled field.
        if (enrollParams.apkamPublicKey == null &&
            enrollParams.signingAlgo == null &&
            enrollParams.apsk == null &&
            enrollParams.apskLegacy == null &&
            enrollParams.metadata == null) {
          throw IllegalArgumentException(
              'enroll:update must name at least one of apkamPublicKey, '
              'signingAlgo, apsk, apskLegacy or metadata');
        }
        // Refused explicitly rather than silently ignored: an enrollment
        // amending itself must never reach its own grants or approval state,
        // so a request that asks is told why rather than obeyed in part.
        if (enrollParams.namespaces != null) {
          throw IllegalArgumentException(
              'enroll:update cannot change namespaces: an enrollment amending '
              'itself must not be able to widen its own grant');
        }
        break;
      // list, listns and infons carry no enrollParams; the namespace-scoped
      // pair validate their argument in their own handlers.
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
    // act only on a grant that is itself read-only. Read as letter sets, so a
    // non-canonical spelling on either side answers the same question here as
    // everywhere else.
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
    // Read-decide-write from the first line, so the whole of it is one
    // mutation: the record is read, the caller's authority and the record's
    // state are decided against it, and then it is removed with its
    // per-enrollment data.
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

    // A caller may always delete its OWN enrollment, and a connection carrying
    // no enrollment id may delete any. Deleting ANOTHER enrollment requires
    // __manage AND access to EVERY namespace the target holds, the same bar as
    // approve/deny/revoke/fetch and the same exemptions.
    //
    // Asked BEFORE the status checks below, so a caller that may not delete
    // this enrollment does not learn its state from the refusal.
    //
    // Two things rest on this gate. [EnrollmentManager.descendantsOf] climbs
    // `parentEnrollmentId` and fetches each link BY KEY, so deleting a middle
    // link puts everything behind it permanently out of reach of a later
    // cascade. And [_refuseIfApproverNotApproved] permits an enrollment whose
    // approver no longer exists, so deleting that approver is what makes the
    // orphan un-revokable.
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final callerEnrollmentId = inboundConnectionMetadata.enrollmentId;
    if (!AbstractVerbHandler.isCramConnection(inboundConnectionMetadata) &&
        callerEnrollmentId != targetEnrollmentId) {
      // A target holding NO namespaces fails closed. The loop below decides by
      // iterating the target's grants, so an empty map passes it vacuously
      // (zero iterations, no refusal), and the `__manage` requirement lives
      // inside that loop, so it would not be asked either. Such a record would
      // otherwise be the one any enrolled caller could destroy, inverting the
      // rule exactly where the record is most anomalous. Nothing on this
      // server mints one; the gate is for records already on disk.
      //
      // Every path that decides by iterating a target's grants carries its own
      // copy of this refusal (here, the shared approve/deny/revoke/unrevoke
      // gate, and `enroll:fetch`'s), because it is the LOOP that passes such
      // a record and each has its own.
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
