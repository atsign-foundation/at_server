import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
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

  /// The threshold value for the delay interval in milliseconds.
  /// When the last delay in '_delayForInvalidOTPSeries' surpasses this threshold,
  /// the series is reset to [0, initialDelayInMilliseconds] to prevent excessively long delay intervals.
  @visibleForTesting
  int enrollmentResponseDelayIntervalInMillis = Duration(
          seconds: AtSecondaryConfig.enrollmentResponseDelayIntervalInSeconds)
      .inMilliseconds;

  EnrollVerbHandler(super.keyStore);

  @override
  bool accept(String command) => command.startsWith('enroll:');

  @override
  Verb getVerb() => enrollVerb;

  @visibleForTesting
  int enrollmentExpiryInMills =
      Duration(hours: AtSecondaryConfig.enrollmentExpiryInHours).inMilliseconds;

  int _lastInvalidOtpReceivedInMills = 0;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final responseJson = {};

    logger.finer('verb params: $verbParams');
    final operation = verbParams['operation'];
    final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    //Approve, deny, revoke or list enrollments only on authenticated connections
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
            enrollVerbParams!, currentAtSign, responseJson, atConnection);
        break;

      case 'approve':
      case 'deny':
      case 'unrevoke':
        await _handleEnrollmentPermissions(
            (atConnection.metaData as InboundConnectionMetadata),
            enrollVerbParams!,
            currentAtSign,
            operation,
            responseJson,
            response);
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
        await _handleEnrollmentPermissions(
            (atConnection.metaData as InboundConnectionMetadata),
            enrollVerbParams,
            currentAtSign,
            operation,
            responseJson,
            response);
        if (responseJson['status'] == EnrollmentStatus.revoked.name) {
          logger.finer(
              'Dropping connection for enrollmentId: $enrollmentIdFromParams');
          await _dropRevokedClientConnection(enrollmentIdFromParams!,
              forceFlag != null, atConnection, responseJson);
        }
        break;

      case 'list':
        response.data = await _fetchEnrollmentRequests(
            atConnection, currentAtSign,
            enrollVerbParams: enrollVerbParams);
        return;
      case 'fetch':
        response.data = await _fetchEnrollmentInfoById(
            enrollVerbParams, currentAtSign, response);
        return;
    }
    response.data = jsonEncode(responseJson);
    return;
  }

  /// Fetches the enrollment request with enrollment id.
  Future<String> _fetchEnrollmentInfoById(
      EnrollParams? enrollVerbParams, currentAtSign, Response response) async {
    String? enrollmentId = enrollVerbParams?.enrollmentId;

    String enrollmentKey =
        '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$currentAtSign';
    AtData atData;
    try {
      atData = await keyStore.get(enrollmentKey);
    } on KeyNotFoundException {
      throw KeyNotFoundException(
          'An Enrollment with Id: ${enrollVerbParams?.enrollmentId} does not exist or has expired.');
    }
    if (atData.data == null) {
      throw AtEnrollmentException(
          'Enrollment details not found for enrollment id: ${enrollVerbParams?.enrollmentId}');
    }
    EnrollDataStoreValue enrollDataStoreValue =
        EnrollDataStoreValue.fromJson(jsonDecode(atData.data!));
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
  /// Throws "AtEnrollmentException", if the OTP provided is invalid.
  /// Throws [AtThrottleLimitExceeded], if the number of requests exceed within
  /// a time window.
  Future<void> _handleEnrollmentRequest(
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
        _lastInvalidOtpReceivedInMills =
            DateTime.now().toUtc().millisecondsSinceEpoch;
        await Future.delayed(
            Duration(milliseconds: getDelayIntervalInMilliseconds()));
        throw AtEnrollmentException(
            'invalid otp. Cannot process enroll request');
      }
    }

    await validateEnrollmentRequest(enrollParams);

    // When threshold is met, set "_lastInvalidOtpReceivedInMills" and "delayForInvalidOTPSeries"
    // to default values.
    if (((DateTime.now().toUtc().millisecondsSinceEpoch) -
            _lastInvalidOtpReceivedInMills) >=
        enrollmentResponseDelayIntervalInMillis) {
      _lastInvalidOtpReceivedInMills = 0;
      delayForInvalidOTPSeries.clear();
      delayForInvalidOTPSeries.addAll([0, initialDelayInMilliseconds]);
    }

    var enrollNamespaces = enrollParams.namespaces ?? {};
    var newEnrollmentId = Uuid().v4();
    var key =
        '$newEnrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace';
    logger.finer('key: $key$currentAtSign');

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

    AtData enrollData;
    if (atConnection.metaData.authType != null &&
        atConnection.metaData.authType == AuthType.cram) {
      // auto approve request from connection that is CRAM authenticated.
      enrollNamespaces[enrollManageNamespace] = 'rw';
      enrollNamespaces[allNamespaces] = 'rw';
      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      responseJson['status'] = 'approved';
      final inboundConnectionMetadata =
          atConnection.metaData as InboundConnectionMetadata;
      inboundConnectionMetadata.enrollmentId = newEnrollmentId;
      // Store default encryption private key and self encryption key(both encrypted)
      // for future retrieval
      await _storeEncryptionKeys(newEnrollmentId, enrollParams, currentAtSign);
      // store this apkam as default pkam public key for old clients
      // The keys with AT_PKAM_PUBLIC_KEY does not sync to client.
      await keyStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = enrollParams.apkamPublicKey!);
      enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());
    } else {
      enrollmentValue.encryptedAPKAMSymmetricKey =
          enrollParams.encryptedAPKAMSymmetricKey;
      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.pending.name);
      await _storeNotification(key, enrollParams, currentAtSign);
      responseJson['status'] = 'pending';
      enrollData = AtData()
        ..data = jsonEncode(enrollmentValue.toJson())
        // Set TTL to the pending enrollments.
        // The enrollments will expire after configured
        // expiry limit, beyond which any action (approve/deny/revoke) on an
        // enrollment is forbidden
        ..metaData = (AtMetaData()..ttl = enrollmentExpiryInMills);
    }
    logger.finer('enrollData: $enrollData');
    await keyStore.put('$key$currentAtSign', enrollData, skipCommit: true);
    // Remove the OTP from keystore to prevent reuse.
    await keyStore.remove(
        'private:${enrollParams.otp?.toLowerCase()}${AtSecondaryServerImpl.getInstance().currentAtSign}');
  }

  /// Handles enrollment approve, deny and revoke requests.
  /// Retrieves enrollment details from keystore and updates the enrollment status based on [operation]
  /// If [operation] is approve, store the public key in public:appName.deviceName.pkam.__pkams.__public_keys
  /// and also store default encryption private key and default self encryption key in encrypted format.
  Future<void> _handleEnrollmentPermissions(
      InboundConnectionMetadata inboundConnectionMetadata,
      EnrollParams enrollParams,
      currentAtSign,
      String operation,
      Map<dynamic, dynamic> responseJson,
      Response response) async {
    final enrollmentIdFromParams = enrollParams.enrollmentId;
    String enrollmentKey =
        '$enrollmentIdFromParams.$newEnrollmentKeyPattern.$enrollManageNamespace';
    logger.finer(
        'Enrollment key: $enrollmentKey$currentAtSign | Enrollment operation: $operation');
    EnrollDataStoreValue? enrollDataStoreValue;
    EnrollmentStatus? enrollStatus;
    // Fetch and returns enrollment data from the keystore.
    // Throw AtEnrollmentException, IF
    //   1. Enrollment key is not present in keystore
    //   2. Enrollment key is not active
    try {
      enrollDataStoreValue =
          await getEnrollDataStoreValue('$enrollmentKey$currentAtSign');
    } on KeyNotFoundException {
      // When an enrollment key is expired or invalid
      enrollStatus = EnrollmentStatus.expired;
    }
    enrollStatus ??=
        getEnrollStatusFromString(enrollDataStoreValue!.approval!.state);
    // Validates if enrollment is not expired
    if (EnrollmentStatus.expired == enrollStatus) {
      response.isError = true;
      response.errorCode = 'AT0028';
      response.errorMessage =
          'enrollment_id: $enrollmentIdFromParams is expired or invalid';
    }
    if (response.isError) {
      return;
    }
    // Verifies whether the enrollment state matches the intended state
    // Throws AtEnrollmentException, if the enrollment state is different from
    // the intended state
    try {
      _verifyEnrollmentStateBeforeAction(operation, enrollStatus);
    } on AtEnrollmentException catch (e) {
      throw AtEnrollmentException(
          'Failed to $operation enrollment id: $enrollmentIdFromParams. ${e.message}');
    }

    for (MapEntry<String, String> entry
        in enrollDataStoreValue!.namespaces.entries) {
      bool isAuthorised = false;
      try {
        isAuthorised = await isAuthorized(inboundConnectionMetadata,
            namespace: entry.key,
            enrolledNamespaceAccess: entry.value,
            operation: operation);
      } on AtEnrollmentException catch (e) {
        throw AtEnrollmentException(
            'Failed to $operation enrollment id: $enrollmentIdFromParams. ${e.message}');
      }

      if (isAuthorised == false) {
        throw AtEnrollmentException(
            'Failed to $operation enrollment id: $enrollmentIdFromParams. Client is not authorized for namespaces in the enrollment request');
      }
    }
    enrollDataStoreValue.approval!.state = _getEnrollStatusEnum(operation).name;
    responseJson['status'] = _getEnrollStatusEnum(operation).name;
    // Update the enrollment status against the enrollment key in keystore.
    await _updateEnrollmentValueAndResetTTL(
        '$enrollmentKey$currentAtSign', enrollDataStoreValue, operation);
    // when enrollment is approved store the apkamPublicKey of the enrollment
    if (operation == 'approve') {
      var apkamPublicKeyInKeyStore =
          'public:${enrollDataStoreValue.appName}.${enrollDataStoreValue.deviceName}.pkam.$pkamNamespace.__public_keys$currentAtSign';
      var valueJson = {'apkamPublicKey': enrollDataStoreValue.apkamPublicKey};
      var atData = AtData()..data = jsonEncode(valueJson);
      await keyStore.put(apkamPublicKeyInKeyStore, atData);
      await _storeEncryptionKeys(
          enrollmentIdFromParams!, enrollParams, currentAtSign);
    }
    responseJson['enrollmentId'] = enrollmentIdFromParams;
  }

  Future<void> _dropRevokedClientConnection(String enrollmentId, bool forceFlag,
      InboundConnection currentInboundConnection, responseJson) async {
    final inboundPool = InboundConnectionPool.getInstance();
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

  /// Stores the encrypted default encryption private key in <enrollmentId>.default_enc_private_key.__manage@<atsign>
  /// and the encrypted self encryption key in <enrollmentId>.default_self_enc_key.__manage@<atsign>
  /// These keys will be stored only on server and will not be synced to the client
  /// Encrypted keys will be used later on by the approving app to send the keys to a new enrolling app
  Future<void> _storeEncryptionKeys(
      String newEnrollmentId, EnrollParams enrollParams, String atSign) async {
    var privateKeyJson = {};
    privateKeyJson['value'] = enrollParams.encryptedDefaultEncryptionPrivateKey;
    await keyStore.put(
        '$newEnrollmentId.${AtConstants.defaultEncryptionPrivateKey}.$enrollManageNamespace$atSign',
        AtData()..data = jsonEncode(privateKeyJson),
        skipCommit: true);
    var selfKeyJson = {};
    selfKeyJson['value'] = enrollParams.encryptedDefaultSelfEncryptionKey;
    await keyStore.put(
        '$newEnrollmentId.${AtConstants.defaultSelfEncryptionKey}.$enrollManageNamespace$atSign',
        AtData()..data = jsonEncode(selfKeyJson),
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
      AtConnection atConnection, String currentAtSign,
      {EnrollParams? enrollVerbParams}) async {
    Map<String, Map<String, dynamic>> enrollmentRequestsMap = {};
    String? enrollApprovalId =
        (atConnection.metaData as InboundConnectionMetadata).enrollmentId;
    List<String> enrollmentKeysList =
        keyStore.getKeys(regex: newEnrollmentKeyPattern) as List<String>;
    // If connection is authenticated via legacy PKAM, then enrollApprovalId is null.
    // Return all the enrollments.
    if (enrollApprovalId == null || enrollApprovalId.isEmpty) {
      await _fetchAllEnrollments(enrollmentKeysList, enrollmentRequestsMap,
          enrollmentStatusFilter: enrollVerbParams?.enrollmentStatusFilter);
      return jsonEncode(enrollmentRequestsMap);
    }
    // If connection is authenticated via APKAM, then enrollApprovalId is populated,
    // check if the enrollment has access to __manage namespace.
    // If enrollApprovalId has access to __manage namespace, return all the enrollments,
    // Else return only the specific enrollment.
    final enrollmentKey =
        '$enrollApprovalId.$newEnrollmentKeyPattern.$enrollManageNamespace$currentAtSign';
    EnrollDataStoreValue enrollDataStoreValue =
        await getEnrollDataStoreValue(enrollmentKey);

    if (_doesEnrollmentHaveManageNamespace(enrollDataStoreValue)) {
      await _fetchAllEnrollments(enrollmentKeysList, enrollmentRequestsMap,
          enrollmentStatusFilter: enrollVerbParams?.enrollmentStatusFilter);
    } else {
      if (enrollDataStoreValue.approval!.state !=
          EnrollmentStatus.expired.name) {
        enrollmentRequestsMap[enrollmentKey] = {
          'appName': enrollDataStoreValue.appName,
          'deviceName': enrollDataStoreValue.deviceName,
          'namespace': enrollDataStoreValue.namespaces,
          'encryptedAPKAMSymmetricKey':
              enrollDataStoreValue.encryptedAPKAMSymmetricKey,
          'status': enrollDataStoreValue.approval?.state
        };
      }
    }
    return jsonEncode(enrollmentRequestsMap);
  }

  Future<void> _fetchAllEnrollments(List<String> enrollmentKeysList,
      Map<String, Map<String, dynamic>> enrollmentRequestsMap,
      {List<EnrollmentStatus>? enrollmentStatusFilter}) async {
    enrollmentStatusFilter ??= EnrollmentStatus.values;
    for (var enrollmentKey in enrollmentKeysList) {
      EnrollDataStoreValue enrollDataStoreValue =
          await getEnrollDataStoreValue(enrollmentKey);
      EnrollmentStatus enrollmentStatus =
          getEnrollStatusFromString(enrollDataStoreValue.approval!.state);
      if (enrollmentStatusFilter.contains(enrollmentStatus)) {
        enrollmentRequestsMap[enrollmentKey] = {
          'appName': enrollDataStoreValue.appName,
          'deviceName': enrollDataStoreValue.deviceName,
          'namespace': enrollDataStoreValue.namespaces,
          'encryptedAPKAMSymmetricKey':
              enrollDataStoreValue.encryptedAPKAMSymmetricKey,
          'status': enrollDataStoreValue.approval?.state
        };
      }
    }
  }

  bool _doesEnrollmentHaveManageNamespace(
      EnrollDataStoreValue enrollDataStoreValue) {
    return enrollDataStoreValue.namespaces.containsKey(enrollManageNamespace);
  }

  /// Pending enrollments have to be notified to clients with __manage namespace - rw access
  /// So store a self notification with key  <enrollmentId>.new.enrollments.__manage and value containing encrypted APKAM symmetric key
  Future<void> _storeNotification(
      String key, EnrollParams enrollParams, String atSign) async {
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
      final atNotification = (AtNotificationBuilder()
            ..notification = '$key$atSign'
            ..fromAtSign = atSign
            ..toAtSign = atSign
            ..ttl = 24 * 60 * 60 * 1000
            ..type = NotificationType.self
            ..opType = OperationType.update
            ..atValue = jsonEncode(notificationValue))
          .build();
      final notificationId =
          await NotificationUtil.storeNotification(atNotification);
      logger.finer('notification generated: $notificationId');
    } catch (e, trace) {
      logger.severe(
          'Exception while storing notification key ${AtConstants.enrollmentId}. Exception $e. Trace $trace');
      rethrow;
    }
  }

  /// Verifies whether the enrollment state matches the intended state.
  /// Throws AtEnrollmentException: If the enrollment state is different
  /// from the intended state.
  void _verifyEnrollmentStateBeforeAction(
      String? operation, EnrollmentStatus enrollStatus) {
    if (operation == 'approve' && EnrollmentStatus.pending != enrollStatus) {
      throw AtEnrollmentException(
          'Cannot approve a ${enrollStatus.name} enrollment. Only pending enrollments can be approved');
    }
    if (operation == 'revoke' && EnrollmentStatus.approved != enrollStatus) {
      throw AtEnrollmentException(
          'Cannot revoke a ${enrollStatus.name} enrollment. Only approved enrollments can be revoked');
    }
    if (operation == 'unrevoke' && EnrollmentStatus.revoked != enrollStatus) {
      throw AtEnrollmentException(
          'Cannot un-revoke a ${enrollStatus.name} enrollment. Only revoked enrollments can be un-revoked');
    }
  }

  /// Checks whether an enrollment with the same appName and deviceName already exists for the given request.
  /// If a matching enrollment is found, [AtEnrollmentException] exception is thrown.
  /// Otherwise, the enrollment request is accepted.
  @visibleForTesting
  Future<void> validateEnrollmentRequest(EnrollParams enrollParams) async {
    // Fetches all the enrollment keys from the keystore.
    List<dynamic> enrollmentKeys = keyStore.getKeys(regex: 'enrollments');

    // Iterate through the existing enrollments and verify that there is no enrollment with the same
    // appName and deviceName combination, and a status of 'pending' or 'approved'
    for (String key in enrollmentKeys) {
      AtData atData = AtData();
      try {
        atData = await keyStore.get(key);
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
        throw AtEnrollmentException(
            'Another enrollment with id $enrollmentId exists with the app name: ${enrollParams.appName} and device name: ${enrollParams.deviceName} in ${enrollDataStoreValue.approval?.state} state');
      }
    }
  }

  Future<void> _updateEnrollmentValueAndResetTTL(String enrollmentKey,
      EnrollDataStoreValue enrollDataStoreValue, String operation) async {
    AtData atData = AtData()..data = jsonEncode(enrollDataStoreValue.toJson());
    // If an enrollment is approved, we need the enrollment to be active
    // to subsequently revoke the enrollment. Hence reset TTL and
    // expiredAt on metadata.
    if (operation == 'approve') {
      // Fetch the existing data
      AtMetaData? enrollMetaData = await keyStore.getMeta(enrollmentKey);
      // Update key with new data
      // Update ttl value to support auto expiry of APKAM keys
      enrollMetaData?.ttl =
          enrollDataStoreValue.apkamKeysExpiryDuration.inMilliseconds;
      atData.metaData = enrollMetaData;
    }
    await keyStore.put(enrollmentKey, atData, skipCommit: true);
  }

  void _validateParams(EnrollParams? enrollParams, String operation,
      InboundConnection inboundConnection) {
    switch (operation) {
      case 'request':
        if (enrollParams!.appName.isNullOrEmpty) {
          throw AtEnrollmentException(
              'appName is mandatory for enroll:request');
        }

        if (enrollParams.deviceName.isNullOrEmpty) {
          throw AtEnrollmentException(
              'deviceName is mandatory for enroll:request');
        }

        if (enrollParams.apkamPublicKey.isNullOrEmpty) {
          throw AtEnrollmentException(
              'apkam public key is mandatory for enroll:request');
        }

        if (enrollParams.otp != null) {
          //encryptedAPKAMSymmetricKey is mandatory for new client enrollments
          if (enrollParams.encryptedAPKAMSymmetricKey.isNullOrEmpty) {
            throw AtEnrollmentException(
                'encrypted apkam symmetric key is mandatory for new client enroll:request');
          }
          if (enrollParams.namespaces == null ||
              enrollParams.namespaces!.isEmpty) {
            throw AtEnrollmentException(
                'At least one namespace must be specified for new client enroll:request');
          }
        }

        break;
      case 'approve':
        if (enrollParams!.enrollmentId.isNullOrEmpty) {
          throw AtEnrollmentException(
              'enrollmentId is mandatory for enroll:approve');
        }
        if (enrollParams.encryptedDefaultEncryptionPrivateKey.isNullOrEmpty) {
          throw AtEnrollmentException(
              'encryptedDefaultEncryptionPrivateKey is mandatory for enroll:approve');
        }
        if (enrollParams.encryptedDefaultSelfEncryptionKey.isNullOrEmpty) {
          throw AtEnrollmentException(
              'encryptedDefaultSelfEncryptionKey is mandatory for enroll:approve');
        }
        break;
      case 'revoke':
      case 'deny':
      case 'unrevoke':
        if (enrollParams!.enrollmentId.isNullOrEmpty) {
          throw AtEnrollmentException(
              'enrollmentId is mandatory for enroll:revoke/enroll:deny');
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
    if (delayForInvalidOTPSeries.last >=
        enrollmentResponseDelayIntervalInMillis) {
      return delayForInvalidOTPSeries.last;
    }
    delayForInvalidOTPSeries.add(delayForInvalidOTPSeries.last +
        delayForInvalidOTPSeries[delayForInvalidOTPSeries.length - 2]);
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
}
