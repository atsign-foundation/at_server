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

  /// A list storing a series of delay intervals for handling invalid OTP series.
  /// The series is initially set to [0, [initialDelayInMilliseconds]] and is updated using the Fibonacci sequence.
  @visibleForTesting
  List<int> delayForInvalidOTPSeries = <int>[0, initialDelayInMilliseconds];

  /// The maximum value for the delay interval in milliseconds.
  @visibleForTesting
  int maxDelayInMillis = Duration(
          seconds: AtSecondaryConfig.enrollmentResponseDelayIntervalInSeconds)
      .inMilliseconds;

  /// The largest enrollment record the atServer will store, measured on its
  /// JSON encoding — the string that lands in the keystore.
  ///
  /// One bound on the whole record rather than one per opaque field. A
  /// per-field cap bounds nothing while a sibling field is uncapped, and that
  /// was the state this replaced: `apsk` was capped while `metadata` — which
  /// carries the enrollment's key package, the largest blob in play — was not,
  /// so the cap sat on the one field nobody would use to make a record big.
  /// It also means a field added later is covered without anyone remembering
  /// to cap it.
  ///
  /// The record's contents are opaque, so nothing about them can be validated;
  /// a bound is all the server can meaningfully impose. What it protects is
  /// not disk: the record is read on every verb command and held in
  /// [EnrollmentManager]'s cache, which is evicted only on write, so an
  /// oversized record occupies server memory for the process's life. It is
  /// also returned whole by `enroll:list`, and its `metadata` by
  /// `enroll:listns` for every approved enrollment in a namespace — so one fat
  /// record inflates every discovery response, for every caller.
  ///
  /// 500KB is far above any legitimate record (ML-DSA-65's public half, the
  /// largest key in play, is ~2.6KB base64-encoded, and a record holds a
  /// handful) and far below the ~10MB an inbound connection will buffer, which
  /// is otherwise the only ceiling on a request that reaches this path with
  /// nothing but an OTP.
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
    // 'list', 'listns' and 'infons' carry no enrollParams JSON body — the
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
      // Folded here, once, for the same reason `pkam` folds the id it reads,
      // and to EXACTLY the keystore's fold: trimmed, lowercased, spaces
      // stripped. The keystore normalises every key that way, so a
      // non-canonical spelling resolves to the SAME record while comparing
      // unequal to the id held on the connection. Every id comparison on the
      // revoke path — the self-revoke refusal, the descendant walk, the
      // caller-in-cascade and last-root refusals, and the connection drop — is
      // a string comparison against this value, so an unfolded params id makes
      // each of them silently vacuous while the record is still written
      // revoked. The last-root refusal is the worst of them: it excludes the
      // act's own targets by KEY, and a key built from an unfolded id excludes
      // nothing, so the enrollment being revoked is counted as the root that
      // survives the revoke.
      //
      // Ids are server-issued uuids and already canonical, so this rejects
      // nothing that works today. It does mean a non-canonical spelling now
      // behaves exactly like the canonical one wherever it previously fell
      // through a guard — `enroll:fetch` of one's own enrollment and a
      // self-`enroll:update` included. That is the intended reading of "the
      // same enrollment", and is called out here because a fold that makes
      // previously-refused requests succeed should be a decision rather than
      // a side effect. It also means an id of nothing but whitespace folds to
      // empty and is refused by _validateParams below as a missing id, rather
      // than being carried into a key that names no enrollment.
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
          // The cascaded enrollments too, and the whole INTENDED set rather
          // than the subset this call flipped. A descendant left holding an
          // open authenticated connection goes on working until it happens to
          // reconnect, which is most of what the cascade exists to stop — and
          // on a retry after a part-way failure the flipped set is empty for
          // precisely those enrollments.
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
    // Note: The enrollmentId is verified for null check in _validateParams.
    final String targetEnrollmentId = enrollVerbParams!.enrollmentId!;
    EnrollDataStoreValue enrollDataStoreValue =
        await enMgr.getEnrollmentById(targetEnrollmentId);

    // enroll:fetch returns the enrollment's encryptedAPKAMSymmetricKey (a
    // secret). A caller may always fetch its OWN enrollment (and a
    // no-enrollmentId CRAM/owner connection may fetch any). Fetching ANOTHER
    // enrollment requires __manage AND access to EVERY namespace the target
    // holds — the same bar as approve/deny/revoke.
    //
    // "EVERY namespace" includes __manage itself, so a '__manage:r'
    // administrator cannot fetch a '__manage:rw' enrollment even where it
    // covers every other namespace the target holds. That is a statement
    // about authority over the target, not about the secrecy of the field:
    // enroll:list returns the same encryptedAPKAMSymmetricKey for every
    // enrollment on the atSign to any caller holding __manage at all, 'r'
    // included. This gate is not what keeps that value from a read-only
    // administrator, and must not be read as though it were.
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final callerEnrollmentId = inboundConnectionMetadata.enrollmentId;
    if (callerEnrollmentId != null &&
        callerEnrollmentId.isNotEmpty &&
        callerEnrollmentId != targetEnrollmentId) {
      // The remedy names the connections that carry no enrollment id at all
      // rather than "an owner", because that is the condition this gate is
      // keyed on: CRAM, owner and legacy PKAM all take the exempt branch.
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

    // Structural checks plus a size pre-filter, before anything is created
    // or an OTP is spent. The record itself is bounded at each write.
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

    // The throttle and the OTP gate above stay OUTSIDE the section. Neither
    // reads or writes an enrollment, and the invalid-OTP arm deliberately
    // sleeps for a growing interval before it answers — holding this atSign's
    // one enrollment-mutation lock across that would let a stream of wrong
    // passcodes stall every approve, revoke and cap arming on the atSign.
    //
    // What is inside is the part that decides against stored enrollments and
    // writes: a retrofit reads its predecessor, checks it is approved, reads
    // its stored deadline and mints a successor carrying its grants — so a
    // revoke of that predecessor landing mid-decision would otherwise be
    // answered by a fresh, approved credential holding exactly what the
    // revoke was taking away.
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

    if (atConnection.metaData.authType == AuthType.cram) {
      // A CRAM-authenticated connection is allowed a 'duplicate' enrollment
      // request. See #2208
      logger.warning('CRAM-authenticated connection - i.e. initial enrollment;'
          ' will replace the existing initial enrollment, if any');
    } else if (carriesEnrollment(inboundConnectionMetadata)) {
      // A self-enrollment keeps its app's own (appName, deviceName): a
      // retrofit is the same app re-enrolling itself, and sibling clones of
      // one keyfile share those names, each needing to coexist with the
      // approved enrollments the others already spawned. Uniqueness of
      // (appName, deviceName) among live enrollments therefore ends on this
      // branch by design. Keyed on the enrollment the connection carries,
      // exactly as the retrofit branch below is.
    } else {
      // Every other connection must not duplicate an existing enrollment's
      // (appName, deviceName).
      await preventDuplicateEnrollRequest(enrollParams);
    }
    // Every path that installs key material: the CRAM auto-approve, the
    // retrofit and the OTP request alike. After the (appName, deviceName)
    // rule, so a request that breaks both is told about the one it can fix by
    // renaming; before anything is written, so a refusal persists nothing.
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
    // At most one of the two is set — _validateEnrollParams refused the request
    // that carried both, above.
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
      // Before any write: a refusal must not leave a published _apsk behind
      // for an enrollment that was never created.
      _validateRecordSize(enrollmentValue);

      // This branch used to copy the enrolling app's APKAM public key into
      // `at_pkam_publickey` "for old clients". It no longer does, and the
      // reason is a separation of concerns rather than a tightening:
      // `at_pkam_publickey` is the credential for LEGACY PKAM authentication,
      // which by definition supplies no enrollment id. An `enroll:request`
      // produces an APKAM credential, which always authenticates WITH one. A
      // key minted for the second has no business becoming the first.
      //
      // The copy gave one keypair two identities with separate lifecycles —
      // revoking the enrollment left the same key authenticating over the
      // legacy path — and, being an unconditional write, it also DESTROYED
      // any legacy credential the atSign already had. That second effect is
      // the sharper one: `enroll:request` is deliberately repeatable on a
      // CRAM connection, so every repeat clobbered the key again.
      //
      // An atSign onboarded by an older server still held such a copy. It is
      // dealt with at startup, before any client connects: a flat key that is
      // a copy of a root's key is deleted, and anything else migrates into
      // the `primary` enrollment. See
      // [EnrollmentManager.migrateFlatKeyAtStartup].
      // Publish the client-composed `_apsk` signing key, if it sent one.
      await _publishApskSigningKey(
          newEnrollmentId, enrollmentValue, currentAtSign);
      AtData enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());

      await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.approved);
      return;
    }

    // A connection that already holds an enrollment retrofits itself: it
    // enrols a FRESH enrollment that REPLACES the one it authenticated as.
    // Auto-approved with no human step and no OTP, that existing approved
    // enrollment being the authority — and because the successor replaces
    // rather than descends, it holds exactly the predecessor's grants. The
    // predecessor is capped rather than removed, and only once the successor
    // has authenticated, so sibling clones of the same keyfile can still
    // retrofit until the cap elapses.
    //
    // What retrofit is FOR: splitting a shared keyfile into per-device
    // credentials. Every party to that already holds an enrollment, so the
    // branch is entered by a connection CARRYING one, whatever authenticated
    // it: the enrollment id on the connection names what is being replaced,
    // and its approval is checked below. A connection carrying none has no
    // enrollment to replace and no id to name one with.
    //
    // ⚠️ Keyed on the id rather than on the auth type, and placed AFTER the
    // CRAM auto-approve above deliberately: a CRAM connection carries the id
    // it has just minted, so an id-keyed gate ahead of the auto-approve
    // would capture that connection's next request as a retrofit. at_auth
    // throws unless a first enrollment comes back `approved`, so onboarding
    // would break for every new user. The CRAM branch is therefore tested
    // FIRST and by auth type, and this one by the enrollment carried.
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
      // A retrofit is a ONCE-OFF. A device gets one no-approver migration, not
      // a series: re-enrolling a successor would be a second migration with no
      // human in the loop, each link restarting the key-expiry clock — so an
      // enrollment with a one-hour term could renew itself indefinitely — and
      // each adding a record whose loss severs the revocation cascade behind
      // it. A second algorithm change needs an approver again.
      if (predecessor.retrofitPredecessorEnrollmentId != null) {
        throw UnAuthorizedException(
            'Enrollment $predecessorId is itself a replacement, and a '
            'replacement may not be replaced without an approver');
      }
      // Escalation first, so a request naming MORE than the predecessor holds
      // keeps its own diagnosis rather than being reported as a mismatch.
      verifyNoEscalation(predecessor.namespaces, enrollNamespaces);
      // Then the replacement rule. A retrofit carries its predecessor's grants
      // verbatim and does not choose its own.
      requireGrantsMatchPredecessor(predecessor.namespaces, enrollParams.namespaces);
      enrollmentValue.namespaces = Map.of(predecessor.namespaces);

      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      // The successor records what it REPLACED, which is what the retrofit cap
      // reads to know whose expiry to put a clock on.
      //
      // ⛔ Not for revocation. The revoke path does NOT walk this edge: a
      // retrofit produces a peer, the same principal re-keyed, so revoking a
      // superseded credential must not take the one that superseded it — an
      // operator retiring an old key would otherwise kill the device's current
      // one. A successor is reached through the approver it INHERITS, on the
      // line below.
      enrollmentValue.retrofitPredecessorEnrollmentId = predecessorId;
      // A retrofit produces a PEER of its predecessor, not a child: the same
      // principal re-keyed. So it takes the predecessor's place in the
      // approval graph as well as its grants — whoever admitted the
      // predecessor admitted this. Leaving it null would make a retrofit an
      // escape hatch from the approval cascade: revoking the approver would
      // reach the predecessor and stop, while the successor it had just been
      // replaced by went on authenticating.
      enrollmentValue.parentEnrollmentId =
          predecessor.parentEnrollmentId;
      // The successor inherits the predecessor's key-expiry posture unless
      // the request states its own. Time is a separate axis from grants: the
      // successor carries the predecessor's grants exactly, but it may hold a
      // shorter life than the credential it replaced.
      if (enrollParams.apkamKeysExpiryDuration == null) {
        enrollmentValue.apkamKeysExpiryDuration =
            predecessor.apkamKeysExpiryDuration;
      }
      // A stated posture may narrow the predecessor's, never widen it.
      // `verifyNoEscalation` covers namespaces; TIME is the other axis a
      // stolen keyfile would want to widen, and this branch is the one
      // enrollment path with no human in the loop to notice. Zero is the
      // keystore's "never expires" and a negative value skips the ttl write
      // altogether, so both are ways of asking for a permanent credential —
      // against a time-bound predecessor, neither is honoured.
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
      // write while the predecessor's is already running — so an equal term
      // always expires later in absolute time, by exactly the predecessor's
      // age. Worse, it is vacuous in the case that matters most: it reads
      // `apkamKeysExpiryDuration` off the predecessor's VALUE, while a capped
      // predecessor's real deadline lives only in its RECORD metadata. A CRAM
      // root carries posture 0, is capped to now+grace, and a successor asking
      // for 0 passes every disjunct above and is written immortal — minted by
      // a credential that dies within the grace.
      //
      // So bound the successor by the predecessor's stored DEADLINE. The
      // POSTURE is narrowed rather than the ttl written below, because
      // `retrofitCapTtlMillis` takes the LATER of the stored expiry and
      // `createdAt + term`: leaving a full-length term on the record would let
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
        // Zero is the keystore's "never expires", so a spent or nearly-spent
        // predecessor must not round its successor up to immortal.
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
          // Carried to the write as an ABSOLUTE. A ttl is re-anchored at the
          // instant of the write, so writing the bound as a duration lands it
          // at the predecessor's deadline PLUS the intervening work — which is
          // past the bound, in the one direction that matters.
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
      // The successor's record expires per its (inherited or stated)
      // key-expiry posture, exactly as the ordinary approve path writes it —
      // the retrofit copies the predecessor's expiry, it does not grant
      // immortality. A ttl of zero is the keystore's "never expires",
      // matching a predecessor with no posture.
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
      // that this server wrote a record: the successor's APKAM private half is
      // persisted client-side, so a keyfile write that fails would leave it
      // existing here and nowhere else — with a clock already running on the
      // predecessor, which is by then the only credential that still works.
      // The cap is armed by the successor's FIRST PKAM authentication instead,
      // which is what proves the private half survived and is usable. See
      // [EnrollmentManager.armRetrofitCapOnFirstAuth].
      return;
    }

    // OK it's a standard enrollment request.
    // - send a notification to be received by an approver app
    // - store the enrollment in 'pending' state
    enrollmentValue.encryptedAPKAMSymmetricKey =
        enrollParams.encryptedAPKAMSymmetricKey;
    enrollmentValue.approval = EnrollApproval(EnrollmentStatus.pending.name);
    responseJson['status'] = 'pending';
    // Every check before the notification: an approver must not be told
    // about a request that was refused and never stored.
    _validateRecordSize(enrollmentValue);
    await _storeNotification(enrollmentKey, enrollParams, currentAtSign);
    AtData enrollData = AtData()
      ..data = jsonEncode(enrollmentValue.toJson())
      // Set TTL to the pending enrollments.
      // The enrollments will expire after configured
      // expiry limit, beyond which any action (approve/deny/revoke) on an
      // enrollment is forbidden
      ..metaData = (AtMetaData()..ttl = enrollmentExpiryInMills);

    await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.pending);
  }

  /// Rejects any requested grant the predecessor enrollment does not hold.
  ///
  /// Subset per namespace and per access letter: `r` fits under `rw`, never
  /// the reverse. A predecessor's `*` grant covers any ordinary namespace at
  /// letters it carries — mirroring the server's own authorisation — but
  /// `__manage` and `*` themselves must be held literally: `*` does not imply
  /// `__manage` anywhere else in the server, and it must not here.
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
  /// A retrofit REPLACES its predecessor rather than descending from it, so it
  /// carries the predecessor's grants and does not choose its own. Stating
  /// [requested] is optional: omit it and the predecessor's grants are
  /// inherited, state it and it must name exactly them.
  ///
  /// Refused rather than reconciled, in both directions. Silently widening a
  /// narrower request would hand a caller authority it never asked for.
  /// Silently honouring one would retire a working credential in favour of a
  /// successor that cannot do what it replaced — a loss that surfaces at the
  /// next thing the app does, far from the request that caused it.
  ///
  /// Escalation is rejected before this by [verifyNoEscalation], which keeps
  /// its own diagnosis. What reaches the throw here is anything that is not
  /// literally the predecessor's map — usually fewer namespaces or narrower
  /// letters, but also a request that names MORE namespaces without escalating,
  /// as `{'*':'rw','wavi':'rw'}` does against a predecessor holding `{'*':'rw'}`:
  /// `wavi` falls under the wildcard so no grant is gained, and the request is
  /// still refused because a replacement states its predecessor's grants or
  /// states nothing.
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

  /// Handles enrollment approve, deny, revoke and unrevoke requests.
  /// Retrieves enrollment details from keystore and updates the enrollment status based on [operation]
  /// If [operation] is approve, store encrypted encryption keys
  /// Returns every id the revoke INTENDED to revoke by cascade, so the caller
  /// can drop their connections. Deliberately not the subset this call
  /// actually flipped: a retry after a part-way failure finds the descendants
  /// already revoked, so the flipped set is empty for exactly the enrollments
  /// whose connections still need dropping. The response field reports the
  /// flipped set, which is the honest answer to "what did this command
  /// change"; the two are different questions.
  ///
  /// Empty for every operation but `revoke`, and for a revoke whose target has
  /// no descendants.
  Future<List<String>> _handleApproveDenyRevokeUnrevoke(
      EnrollmentManager enMgr,
      InboundConnectionMetadata inboundConnectionMetadata,
      EnrollParams enrollParams,
      currentAtSign,
      String operation,
      Map<dynamic, dynamic> responseJson,
      Response response) async {
    // Everything below is read-decide-write across the whole store, so it
    // runs as this atSign's only in-flight enrollment mutation.
    //
    // The SPAN is the point rather than the write. A revoke reads the target,
    // walks its descendants, asks whether any unexpiring root would survive
    // the act, and only then writes; two of those at once each counted the
    // root the other was about to remove and left the atSign with none.
    // Serialising the writes alone would not have changed that by one record.
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
      // When an enrollment key is expired or invalid
      status = EnrollmentStatus.expired;
    }
    status ??= EnrollmentStatus.values.byName(enVal!.approval!.state);
    // Validates if enrollment is not expired
    if (EnrollmentStatus.expired == status) {
      response.isError = true;
      response.errorCode = 'AT0028';
      response.errorMessage = 'enrollment_id: $enId is expired or invalid';
      return const [];
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

    // A target holding NO namespaces passes the loop below vacuously — zero
    // iterations, no refusal — and the `__manage` requirement lives inside
    // that loop too, so it is not asked either. Gated on caller-vs-target the
    // way delete is: a CRAM or owner connection carries no enrollment id and
    // must still be able to act on such a record, or the most anomalous
    // enrollment on the atSign becomes the one nothing can clear up. The self
    // clause keeps a forced self-revoke working.
    //
    // A legacy-PKAM connection carries no enrollment id either, so it takes
    // the exempt branch alongside CRAM and owner — which is what leaves an
    // atSign whose only owner access is the flat keyfile able to clear up
    // such a record.
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
      // asks whether the caller covers the target's namespaces, and a fully
      // privileged enrollment admits administrators holding exactly the
      // grants it holds — so an enrollment the target admitted passes that
      // check against the very enrollment that admitted it, while being a
      // descendant of it. The cascade would therefore take the caller with
      // it. On a two-enrollment atSign that is stranding reached without
      // anyone self-revoking, which is why neither the self-revoke refusal on
      // the way in nor the liveness check below ever sees it.
      if (callerId != null && cascadeIds.contains(callerId)) {
        throw AtEnrollmentRevokeException(
            'Cannot revoke enrollment $enId: $callerId, the enrollment making '
            'this request, descends from it by approval and would be revoked '
            'by the same cascade. Revoke $enId from an enrollment outside the '
            'chain of approvals beneath it');
      }

      // Revoking a fully privileged enrollment may not leave the atSign
      // without one. Asked for EVERY such revoke, not only a self-revoke:
      // gating it on `enId == callerId` missed the case where a root with a
      // finite lifetime revokes the atSign's other root and then expires,
      // which strands it just as completely and trips none of the other
      // refusals — the caller is not the target, and a target with no
      // descendants cannot contain the caller in its cascade.
      //
      // The survivor has to be PERMANENT. A fully privileged root with a
      // finite life does not answer the question, it only defers it — the
      // atSign keeps the ability to restore a root until that date and loses
      // it afterwards, with nothing at the time of the revoke to say so. A
      // caller that is itself an unexpiring root answers the question by
      // existing, since it is not in the excluded set. A caller that is NOT
      // fully privileged is never counted whatever its lifetime, because
      // restoring a root means APPROVING one, and approving is checked per
      // namespace against what the approver itself holds: only a root can
      // admit a root, so a non-root caller surviving the act answers a
      // different question from the one being asked.
      //
      // Asked over what SURVIVES the cascade, not over what is stored: the
      // descendants are still `approved` while this runs, so counting them
      // would report the atSign safe at the moment it is being stranded.
      //
      // Asked of the ACT, not of the target. What strands an atSign is a
      // fully privileged enrollment being taken away, and the command names
      // only the top of the subtree it removes — so a target holding no full
      // privilege of its own may still carry one away in its cascade. A guard
      // reading the target's grants alone sees nothing to protect in that
      // shape and lets the atSign's last root go, silently: the caller is not
      // the target, so the self-revoke and descends-from refusals are both
      // quiet, and the cascade is exactly where the root goes.
      //
      // Both halves ask `EnrollmentManager.isUsableRootEnrollment` rather
      // than reading the grants, so a record with no credential RECORDED for
      // it is not counted as a root taken away — the same bar the survival
      // question applies, because an act that removes no such root cannot
      // strand an atSign whatever the roster says. That bar is about what the
      // record holds, not about whether anyone holds the private half; see
      // `EnrollmentManager.isUsableRootEnrollment` for what it does and does
      // not establish.
      //
      // Both halves are load-bearing. The target is asked about because it is
      // removed too and its own cascade cannot contain it; the cascade is
      // asked about because the enrollments in it are removed by the same act.
      //
      // Skipped for a connection carrying no enrollment id — CRAM, owner or
      // legacy PKAM — because such a connection can always mint a fresh
      // enrollment, so no act of its can leave the atSign unable to approve a
      // replacement. The flat credential such a connection may hold is itself
      // counted as a surviving root by the liveness question below, so the
      // exemption and that count agree about what the atSign can fall back
      // on.
      if (callerId != null) {
        // Cheapest question first: this reads one record per enrollment the
        // act removes, while the liveness question below walks the whole
        // keystore. An act that removes no fully privileged enrollment cannot
        // strand the atSign whatever else is stored.
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

    // The cascade goes FIRST, before the target's own write. The order is
    // about what a retry does: revoking the target first and then failing
    // part-way through the subtree leaves a state where the same command
    // comes back "Cannot revoke a revoked enrollment", so the cascade can
    // never be completed. This order fails the other way — the subtree is
    // revoked and the target is not — and re-running the command finishes
    // the job.
    //
    // One moment for the whole command — the enrollment named and every
    // enrollment the cascade takes. See EnrollmentManager.revokeAll.
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

    // The revocation history, for the enrollment this command NAMED. The
    // cascade wrote its own above, with the same provenance and `cascadedFrom`
    // pointing here.
    //
    // Grants are read off the record BEFORE the write, and recorded on the
    // un-revoke too: an event has to say which namespaces it affects without
    // the enrollment, which by then may be reaped.
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
    // A revoke records BEFORE its write and an un-revoke AFTER it, so that a
    // crash in the window always errs towards reporting the namespace as
    // revoked. Over-stating a revocation costs a client a refetch;
    // under-stating one tells it nothing has changed when a credential has
    // just stopped working.
    if (operation == 'revoke') {
      await enMgr.recordRevocationEvents([revocationEvent!]);
    }

    // Record WHO approved, so a later revocation of the approver can take the
    // enrollments it admitted with it. Read off the connection rather than the
    // request: an approver cannot name someone else as the admitting party.
    // Null over a connection carrying no enrollment id — CRAM, owner or
    // legacy PKAM — because there is nothing there to revoke later.
    if (operation == 'approve') {
      final String? approverId = inboundConnectionMetadata.enrollmentId;
      enVal.parentEnrollmentId =
          (approverId != null && approverId.isNotEmpty) ? approverId : null;
    }

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
      // Update ttl value to support auto expiry of APKAM keys.
      //
      // A non-positive posture is a request for a credential that does not
      // expire, and is written as ttl 0 — the keystore's "never expires" —
      // rather than passed through. A NEGATIVE ttl is not "no expiry": the
      // metadata builder derives `expiresAt` only for `ttl >= 0`, so a
      // negative one skips the derivation and leaves the PENDING record's
      // expiry standing on the approved enrollment. The credential then
      // carries a deadline nobody asked for, inherited from the window it had
      // to be approved in — and a later retrofit cap, measuring against that
      // stale value, appears to EXTEND the enrollment rather than shorten it.
      final int postureMs = enVal.apkamKeysExpiryDuration.inMilliseconds;
      emd.ttl = postureMs > 0 ? postureMs : 0;
      atData.metaData = emd;
    }
    // A write that says nothing about expiry must not MOVE expiry. The
    // metadata builder re-derives `expiresAt = now + ttl` from the RETAINED
    // ttl on any write that does not assert the stored absolute back, so a
    // revoke, deny or unrevoke would silently restart the enrollment's APKAM
    // key-expiry clock — and with it any retrofit cap standing on the record.
    // `approve` is the deliberate exception: it starts that clock, just above.
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

    // when enrollment is approved store the encrypted encryption keys
    if (operation == 'approve') {
      await _storeEncryptionKeys(enId, enrollParams, enVal);
      // Publish the `_apsk` signing key the enrollee composed on its request.
      // Read off the RECORD, not off these approve params: the value is the
      // enrollee's, and an approver must not be able to substitute a signing
      // key for the enrollment it is approving.
      await _publishApskSigningKey(enId, enVal, currentAtSign);
    }
    responseJson['enrollmentId'] = enId;
    // Only when it happened, so no existing response shape changes.
    if (cascaded.isNotEmpty) {
      responseJson['cascadedEnrollmentIds'] = cascaded;
    }
    return cascadeIds;
  }

  /// Refuses an operation that would make [enId] active while the enrollment
  /// that APPROVED it is not.
  ///
  /// This is what stops the revoke cascade being one-way. `enroll:unrevoke` on
  /// an enrollment the cascade swept up would otherwise resurrect exactly the
  /// orphan it removed.
  ///
  /// It follows the approval edge, not the replacement one. Revoking an
  /// enrollment does not revoke what replaced it — a retrofit produces a peer,
  /// the same principal re-keyed — so there is no orphan to resurrect there
  /// and nothing to refuse.
  ///
  /// `unrevoke` is the transition this actually governs. `approve` is checked
  /// too, so the rule reads the same at every transition into an active state
  /// — but that arm cannot fire as things stand, and saying otherwise credits
  /// it with work it does not do: a PENDING record carries no approver, and
  /// the approver is recorded further down this same operation, after the
  /// gate has run. It is kept as the statement of the invariant, so a future
  /// path that approves a record already naming an approver is covered
  /// without anyone having to notice.
  ///
  /// Two things are always allowed, for DIFFERENT reasons — they were once
  /// documented here as one, which credited the second with the first's job.
  ///
  /// A null [EnrollDataStoreValue.parentEnrollmentId] means nothing here
  /// admitted it: an enrollment approved over an OWNER connection, or one
  /// written before the field existed. That check alone is what stops the rule
  /// barring every enrollment an owner ever admitted.
  ///
  /// An approver that no longer EXISTS is separate, and narrower. It is
  /// permitted because there is nothing left to compare against — but it does
  /// mean `enroll:delete` on an approver is a way to un-revoke what it
  /// admitted, which is the same gap [EnrollmentManager.descendantsOf]
  /// documents for a deleted link.
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
      // The remedy is named and is value-INDEPENDENT: no branch on which
      // identity the connection happens to carry. Glossing a particular
      // identifier instead would be correct for exactly one value and would
      // put a conditional in a refusal path, which a test pinning the message
      // would then pin too.
      throw AtEnrollmentException(
          'enroll:update is self-only: this connection is authenticated as '
          '${connectionMetadata.enrollmentId ?? "the owner"}, not $enId. '
          'Authenticate as $enId to update it');
    }

    // As for approve/deny/revoke/unrevoke: the identity checks above decide
    // from the connection and the id alone, and everything below reads the
    // record, decides against it and writes it back.
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

    // Same checks and the same reasons as enroll:request, applied before
    // anything is written.
    _validateEnrollParams(enrollParams);

    if (enrollParams.apkamPublicKey != null) {
      final newSigningAlgo = enrollParams.signingAlgo ?? enVal.signingAlgo;
      await _verifyApkamPublicKeyPossession(
        enrollmentId: enId,
        apkamPublicKey: enrollParams.apkamPublicKey!,
        signingAlgo: newSigningAlgo,
        signature: enrollParams.apkamPublicKeySignature,
      );
      // A rotation installs key material like any request does. The record
      // re-sending its own current key is not a collision with itself.
      await _refuseKeyHeldByAnotherEnrollment(
          enrollParams.apkamPublicKey!, newSigningAlgo,
          excluding: enId);
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

    // Setting either shape clears the other: one record publishes one value,
    // and this is the operation that moves an enrollment between them — a
    // retrofit that gains a structured key must stop the record claiming the
    // bare one it used to publish.
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

    // The state and ttl are untouched — but an untouched ttl is not an
    // untouched EXPIRY. The metadata builder re-derives `expiresAt = now + ttl`
    // on any write that does not assert the stored absolute back, so without
    // this carry an enrollment could postpone its own retirement indefinitely
    // by amending itself, one `enroll:update` per grace period, and the
    // retrofit cap would be advisory rather than a deadline.
    // The status is read off the record JUST BEFORE the write, never off the
    // snapshot taken at the top of this method. Between the two this method
    // awaits an APKAM signature verification, and a revoke landing in that
    // window would otherwise be UNDONE: `put` moves an enrollment's
    // per-enrollment data to match the status it is handed, so writing
    // `approved` back would return the revoked enrollment's published `_apsk`
    // to the live address the revocation had just parked it from.
    //
    // It REFUSES rather than adjusting, because correcting the status handed
    // to `put` would not be enough. `_publishApskSigningKey` below writes the
    // signing key straight to the approved address without going through
    // `put` at all, so an update carrying an apsk would republish it whatever
    // status the record write used. Nothing is written once the record is no
    // longer approved.
    //
    // `getMeta` is `(await get(key))?.metaData`, so reading the whole record
    // here costs nothing the discarded read did not already cost.
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

    // Republish only when the request carried a new value. An update that says
    // nothing about either shape leaves the published record exactly as it was.
    if (enrollParams.apsk != null || enrollParams.apskLegacy != null) {
      await _publishApskSigningKey(enId, enVal, currentAtSign);
    }

    responseJson['enrollmentId'] = enId;
    // The status just read off the record, not a constant: the write above
    // refuses unless the record is approved, so this cannot disagree with
    // what is on disk.
    responseJson['status'] = current.name;
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
  ///
  /// The signable happens to name a server-issued enrollment id, which is
  /// unique to the atSign that issued it, so this document is incidentally
  /// bound to one atSign. Nothing rests on that: the authorisation above is
  /// what stops a replay.
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

    // Verified through ApkamSignatureVerifier, the same path `pkam:` uses.
    // PKAM is the other place that verifies an APKAM signature against a
    // record's algorithm, and the two must agree byte-for-byte about how a
    // signature is framed: a key that can authenticate has to be installable,
    // and a key installed here has to be able to authenticate afterwards.
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

  /// Refuses a request carrying both `_apsk` shapes, and refuses one whose
  /// payload cannot fit in an enrollment record.
  ///
  /// Both shapes at once is a client error rather than a precedence question:
  /// one record publishes one value, and the server has no basis for choosing
  /// between two the client disagreed with itself about. Refusing is also what
  /// keeps the choice observable — silently preferring one would publish a
  /// signing key the enrollee did not think it had asked for.
  ///
  /// The size check here is a **pre-filter**, not the authority. It runs
  /// before the OTP is validated so an oversized request does not spend a
  /// one-shot passcode on its way to being refused, and it is safe to do early
  /// because these params are strictly larger than the part of the record they
  /// become. [_validateRecordSize] is what actually holds the bound, because
  /// `enroll:update` merges `metadata` and so can grow a record past the cap
  /// with a request that is nowhere near it.
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
  /// Called before every write of a record, on the record as it will be
  /// stored — after any merge — because that is the only measurement the
  /// bound can be stated in. Refused rather than truncated: a truncated record
  /// is unparseable, and the enrollment it describes would be unusable with
  /// nothing to say why.
  ///
  /// On the `enroll:request` path the pre-filter in [_validateEnrollParams]
  /// almost always refuses first, because `EnrollParams.toJson()` emits every
  /// field including the null ones and so encodes larger than the record it
  /// becomes. `enroll:update` is where this check does the work: `metadata`
  /// merges rather than replaces, so a request nowhere near the cap can still
  /// leave a record past it, and no measurement of the request can see that.
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
  /// [EnrollDataStoreValue.apskLegacy] goes out **verbatim**: every deployed
  /// `_apsk` consumer base64-decodes the value as an RSA key, and a JSON string
  /// — quotes and all — is not what that parser reads. [EnrollDataStoreValue.apsk]
  /// is JSON-encoded, which is what makes it unmistakable to those same
  /// consumers: they fail loudly on it rather than mis-reading it.
  ///
  /// The two are mutually exclusive on the wire, so the order here decides
  /// nothing; it is written as a chain only so the null case has one answer.
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
  /// nothing: PKAM verification reads the enrollment record's
  /// `apkamPublicKey` and `signingAlgo`, so `_apsk` is a client-side artefact
  /// and its format belongs to the side that parses it. An enrollment that
  /// sent no value publishes its own signing key from its own connection, or
  /// goes without.
  ///
  /// The server writes it despite never reading it because `_apsk` accepts
  /// writes only from its own enrollment's connection, and at approval that
  /// connection has never existed. The approver needs the record immediately —
  /// it verifies the enrollee's key package against it and signs signing-chain
  /// links over it — so this is the only party that can put it there in time.
  ///
  /// Takes the RECORD rather than a value, so every call site publishes what
  /// the enrollee asked for: an approver handing its own value in would be
  /// substituting a signing key for the enrollment it is approving.
  ///
  /// World-readable, so a same-atSign or peer-atSign verifier can reach it via
  /// plookup. Idempotent: a re-publish is a harmless overwrite with the same
  /// value.
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
    // A connection carrying no enrollment id — CRAM, owner or legacy PKAM —
    // stands over no record to narrow to. Return all the enrollments, and
    // return them whole: this connection holds the atSign itself rather than
    // a delegated share of it, so there is no secret here it is not already
    // entitled to read straight out of the keystore.
    if (authenticatedEnrollmentId == null ||
        authenticatedEnrollmentId.isEmpty) {
      final enrollmentRequestsMap = await enMgr.getEnrollmentsAsJson(
        redactSecrets: false,
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
      // Which projection is the caller's own __manage LETTER, not merely
      // whether it holds the namespace at all.
      //
      // The record carries `encryptedAPKAMSymmetricKey` — the wrapped key an
      // approver needs to admit an enrollment — and the server already states
      // that value's audience elsewhere: the pending-enrollment notification
      // goes to clients holding __manage at `rw`. A read-only administrator
      // can never approve, so it can never have a use for the key; it needs
      // to know which enrollments exist, what each holds and what state each
      // is in, which is what the roster projection carries.
      //
      // enroll:fetch asks a different question of the same data — authority
      // over the TARGET, namespace by namespace — and keeps its own gate.
      // The two are not redundant: fetch answers about one enrollment a
      // caller named, this answers about every enrollment on the atSign.
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
        // The caller's OWN record, whole: it is this enrollment's own key
        // material, which the client that holds the enrollment already has.
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

    await _requireNamespaceAccess(enMgr, atConnection, namespace, 'listns');
    final members = await enMgr.getEnrollmentsForNamespace(namespace);
    return jsonEncode(members);
  }

  /// Facts about [namespace] itself, as opposed to the roster of enrollments
  /// holding it.
  ///
  /// A MAP, and deliberately so. The roster is a list of members and the last
  /// revocation affecting a namespace is not a fact about any member — putting
  /// it there meant the same value on every row under a name that had to
  /// explain why it was in the wrong place. A map also has room for the next
  /// per-namespace fact without touching the roster's shape, which matters
  /// because a deployed client reads that roster as
  /// `if (decoded is! List) return const []` and would take an unrecognised
  /// shape for an empty namespace, silently.
  ///
  /// `lastRevokedAt` is present ALWAYS, null when nothing holding the
  /// namespace has been revoked. An absent key and a key a client failed to
  /// parse are the same thing to a careless reader; an explicit null is an
  /// answer.
  ///
  /// It is derived from the revocation history, which outlives the enrollments
  /// it describes, and it NETS OUT un-revocations — so it can move backwards.
  /// A client deciding whether to refetch must compare it for inequality
  /// rather than order it.
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
  /// Shared rather than restated so the two verbs cannot drift apart — what a
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
    // `*` does not imply `__manage` anywhere else in the server and it must
    // not here. The matcher above falls back to the wildcard for any namespace
    // it holds no explicit grant on, `__manage` included, so without this a
    // caller holding `*` and no `__manage` is admitted to the `__manage`
    // roster and to its revocation history — which is exactly what the
    // general authorisation path refuses.
    if (namespace == EnrollmentConstants.enrollManageNamespace &&
        !_doesEnrollmentHaveManageNamespace(callerEnVal)) {
      throw UnAuthorizedException(
          'Caller enrollment is not authorised for namespace "$namespace":'
          ' it must be held explicitly, and a `*` grant does not confer it');
    }
  }

  /// The caller's access (`r`|`rw`) to [namespace] under the atServer's own
  /// suffix / `*`-wildcard rule, or null if the enrollment has no access.
  /// Mirrors [EnrollmentManager.getEnrollmentsForNamespace]'s match; both `r`
  /// and `rw` satisfy the ≥`r` bar the discovery verb requires.
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

  /// Whether [md] carries an enrollment: an authenticated connection holding
  /// a non-empty enrollment id, which names the record a self-enrollment
  /// replaces. This, and not the auth type, is what selects the retrofit
  /// branch of the request path, the (appName, deviceName) skip that goes
  /// with it, and the mandatory-namespace exemption in `_validateParams`.
  /// Whether that enrollment is APPROVED is checked by the branch, which
  /// reads the record.
  ///
  /// Authentication is part of it because an id is only ever put on a
  /// connection by the authentication that admitted it; an id found on an
  /// unauthenticated connection names nothing the connection proved.
  @visibleForTesting
  static bool carriesEnrollment(InboundConnectionMetadata md) {
    final String? id = md.enrollmentId;
    return md.isAuthenticated && id != null && id.isNotEmpty;
  }

  /// Refuses a request whose (appName, deviceName) an approved or pending
  /// enrollment already holds, with [IllegalStateException].
  ///
  /// Read off the stored roster rather than the visible one, the same walk
  /// [_refuseKeyHeldByAnotherEnrollment] makes. An elapsed-but-unswept record
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
  /// status, already holds that key material — with [IllegalStateException],
  /// and before anything is written.
  ///
  /// One keypair under two names is two identities with separate lifecycles:
  /// revoking one leaves the key authenticating as the other. So a revoked or
  /// denied holder blocks re-enrolment with the same keypair until it is
  /// deleted, and an expired record blocks until the sweep removes it.
  /// [excluding] is the enrollment re-sending its own current key.
  ///
  /// The refusal names the holding enrollment only under `testingMode`, as a
  /// diagnostic for the rigs: to an unauthenticated requester the roster is
  /// not its to read, and an authenticated one can list it.
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
        }

        // Outside the OTP branch deliberately. A request naming no namespaces
        // is only meaningful on the two paths that fill them in on its behalf:
        // CRAM, which grants `__manage` and `*`, and a retrofit, which
        // inherits its predecessor's exactly. Every other path writes the
        // grants the request chose, so an empty map lands an enrollment no
        // caller can ever demonstrate authority over — the per-namespace
        // authorisation loops decide by iterating the TARGET's grants and a
        // target holding none passes them with zero iterations.
        //
        // The exemption is keyed exactly as the request path's branches are:
        // CRAM by auth type, the retrofit by the enrollment the connection
        // carries. Keying the two differently is how an empty-grant record
        // gets minted — a connection admitted here and not there lands on
        // the path that writes the grants the request chose.
        final AuthType? authType = inboundConnection.metaData.authType;
        if (authType != AuthType.cram &&
            !carriesEnrollment(
                inboundConnection.metaData as InboundConnectionMetadata) &&
            (enrollParams.namespaces == null ||
                enrollParams.namespaces!.isEmpty)) {
          throw IllegalArgumentException(
              'At least one namespace must be specified for enroll:request');
        }

        // The access level is client-supplied JSON that is stored verbatim
        // and then read by every authorisation decision on the atSign, so
        // this is the one place a spelling the server does not act on can be
        // kept out of the store. Refused rather than coerced: a grant is an
        // authorisation decision, and guessing what `wr` or `RW` was meant
        // to say hands out an authority nobody asked for. Before this, such
        // a request was accepted and produced an enrollment that could do
        // nothing while still counting as read-only to the checks that ask
        // how powerful it is.
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
        // An update that names nothing to change is a caller bug, not a no-op
        // worth accepting: it costs a write and a sync round for nothing, and
        // it usually means the field the caller meant to set is misspelled.
        if (enrollParams.apkamPublicKey == null &&
            enrollParams.signingAlgo == null &&
            enrollParams.apsk == null &&
            enrollParams.apskLegacy == null &&
            enrollParams.metadata == null) {
          throw IllegalArgumentException(
              'enroll:update must name at least one of apkamPublicKey, '
              'signingAlgo, apsk, apskLegacy or metadata');
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
    // A caller holding write may act on any grant; a caller holding only read
    // may act only on a grant that is itself read-only. Read as letter sets,
    // so a non-canonical spelling on either side answers the same question
    // here as it does everywhere else.
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
    // state are decided against it, and then it is removed — taking its
    // per-enrollment data with it.
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
    // Note: The enrollmentId is verified for the null check in the _validateParams methods.
    // Therefore, when control comes here, enrollmentId will not be null.
    final String targetEnrollmentId = enrollParams!.enrollmentId!;
    EnrollDataStoreValue enVal =
        await enMgr.getEnrollmentById(targetEnrollmentId);

    // A caller may always delete its OWN enrollment (and a no-enrollmentId
    // CRAM/owner connection may delete any). Deleting ANOTHER enrollment
    // requires __manage AND access to EVERY namespace the target holds — the
    // same bar as approve/deny/revoke/fetch, and the same exemptions.
    //
    // Asked BEFORE the status checks below, so a caller that may not delete
    // this enrollment does not learn its state from the refusal it gets.
    //
    // Delete is irreversible and it was the only operation naming a target
    // that asked nothing: `enroll:fetch`, which reads a secret rather than
    // destroying a record, has had this check all along. Two things now rest
    // on it that did not before. `EnrollmentManager.descendantsOf` climbs
    // `parentEnrollmentId` and fetches each link BY KEY, so a delete of a
    // middle link puts everything behind it permanently out of reach of a
    // later cascade. (Expiry severs a chain too, once the scheduled sweep
    // removes the record — see [EnrollmentManager.descendantsOf]. A delete is
    // the half a caller chooses.) And [_refuseIfApproverNotApproved] permits an
    // enrollment whose approver no longer exists, so deleting that approver is
    // what makes the orphan un-revokable.
    final inboundConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final callerEnrollmentId = inboundConnectionMetadata.enrollmentId;
    if (callerEnrollmentId != null &&
        callerEnrollmentId.isNotEmpty &&
        callerEnrollmentId != targetEnrollmentId) {
      // A target holding NO namespaces fails closed. The loop below decides by
      // iterating the target's grants, so an empty map passes it vacuously —
      // zero iterations, no refusal — and the `__manage` requirement lives
      // inside that loop too, so it would not be asked either. An enrollment
      // with an empty grant map would therefore be the one record any enrolled
      // caller could destroy, which inverts the rule exactly where the record
      // is most anomalous.
      //
      // Reachable from storage written by an older build, and that is now the
      // whole of it. Such a record used to be mintable by any AUTHENTICATED
      // `enroll:request` naming no namespaces: it took the `else` branch,
      // getting neither the CRAM branch's `__manage`+`*` nor the retrofit
      // branch's copy of the predecessor's grants, while the "at least one
      // namespace" check sat inside the OTP branch of _validateParams, which
      // an authenticated connection does not enter. That check is outside the
      // OTP branch now and exempts only the two auth types whose grants are
      // filled in for them, so this server no longer mints such a record. The
      // gate stays for the ones already on disk.
      //
      // Every path that decides by iterating a target's grants refuses an
      // empty map before it reaches the loop, for the same reason and in the
      // same words: this gate, the shared approve/deny/revoke/unrevoke gate,
      // and `enroll:fetch`'s. The refusal has to live at each of them because
      // it is the LOOP that passes such a record, and each has its own.
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
