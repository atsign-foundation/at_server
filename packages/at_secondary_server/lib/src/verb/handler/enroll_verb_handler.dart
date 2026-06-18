import 'dart:async';
import 'dart:collection';
import 'dart:convert';

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

  final EnrollmentManager enMgr;
  final NotificationManager notifManager;

  EnrollVerbHandler(
      super.keyStore, super.context, this.enMgr, this.notifManager);

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
    final currentAtSign = context.currentAtSign;
    // Approve, deny, revoke or list enrollments only on authenticated connections
    if (operation != 'request' && !atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException(
          'Cannot $operation enrollment without authentication');
    }
    EnrollParams? enrollVerbParams;

    // Ensure that enrollParams are present for all enroll operation
    // Exclude operation 'list' which does not have enrollParams
    if (verbParams[AtConstants.enrollParams] == null) {
      if (operation != 'list') {
        logger.severe(
            'Enroll params is empty | EnrollParams: ${verbParams[AtConstants.enrollParams]}');
        throw IllegalArgumentException('Enroll parameters not provided');
      }
    } else {
      enrollVerbParams = EnrollParams.fromJson(
          jsonDecode(verbParams[AtConstants.enrollParams]!));
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
      case 'fetch':
        response.data = await _fetchEnrollmentInfoById(
          enMgr,
          enrollVerbParams,
          currentAtSign,
          response,
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
  ) async {
    // Note: The enrollmentId is verified for null check in _validateParams.
    EnrollDataStoreValue enrollDataStoreValue =
        await enMgr.getEnrollmentById(enrollVerbParams!.enrollmentId!);
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

    if (atConnection.metaData.authType != AuthType.cram) {
      // If this is not a CRAM-authenticated connection, then we need to ensure
      // that there is not an existing enrollment with the same info.
      await preventDuplicateEnrollRequest(enrollParams);
    } else {
      // However, if it is a CRAM-authenticated connection, then we should
      // allow a 'duplicate' enrollment request. See #2208
      logger.warning('CRAM-authenticated connection - i.e. initial enrollment;'
          ' will replace the existing initial enrollment, if any');
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
      AtData enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());

      await enMgr.put(newEnrollmentId, enrollData, EnrollmentStatus.approved);
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
    }
    responseJson['enrollmentId'] = enId;
  }

  Future<void> _dropRevokedClientConnection(String enrollmentId, bool forceFlag,
      InboundConnection currentInboundConnection, responseJson) async {
    // Composition-root access (deliberate): the InboundConnectionManager is
    // created after the verb-handler context (during start()), and its live
    // connection pool is server lifecycle state read at request time — not
    // constructor-injectable into this handler.
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

        if (enrollParams.otp != null) {
          //encryptedAPKAMSymmetricKey is mandatory for new client enrollments
          if (enrollParams.encryptedAPKAMSymmetricKey.isNullOrEmpty) {
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
