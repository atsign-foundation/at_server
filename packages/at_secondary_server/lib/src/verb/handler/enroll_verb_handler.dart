import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'abstract_verb_handler.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Verb handler to process APKAM enroll requests
class EnrollVerbHandler extends AbstractVerbHandler {
  static Enroll enrollVerb = Enroll();

  EnrollVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
    logger.finer('verb params: $verbParams');
    final operation = verbParams['operation'];
    final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;

    // Validate the conditions required to process enrollment operation
    _checkEnrollmentOperationParams(verbParams, atConnection, operation);

    late EnrollVerbResponse enrollmentResponse;

    try {
      switch (operation) {
        case 'request':
          // Generate a unique enrollment ID using Uuid for new enrollments
          verbParams['enrollmentId'] = Uuid().v4();
          String enrollmentKey = getEnrollmentKey(verbParams['enrollmentId']!);
          enrollmentResponse = await _handleEnrollmentRequest(enrollmentKey,
              verbParams, currentAtSign, operation, atConnection);
          break;
        case 'update':
          String enrollmentKey = getEnrollmentKey(verbParams['enrollmentId']!,
              isSupplementaryKey: true);
          enrollmentResponse = await _handleEnrollmentRequest(enrollmentKey,
              verbParams, currentAtSign, operation, atConnection);
          break;
        case 'approve':
        case 'deny':
        case 'revoke':
          enrollmentResponse = await _updateEnrollmentApprovalStatus(
              verbParams, currentAtSign, operation);
          break;
        case 'list':
          enrollmentResponse =
              await _listEnrollments(atConnection, currentAtSign);
      }
    } catch (e, stackTrace) {
      logger.severe('Exception: $e\n$stackTrace');
      rethrow;
    }

    if (enrollmentResponse.response.isError) {
      response.isError = true;
      response.errorCode = enrollmentResponse.response.errorCode;
      response.errorMessage = enrollmentResponse.response.errorMessage;
      return;
    }
    response.data = jsonEncode(enrollmentResponse.data);
  }

  /// Ensures each of the enrollment operations has the required parameters
  void _checkEnrollmentOperationParams(
      Map<String, String?>? verbParams, atConnection, operation) {
    if (operation != 'request' && !atConnection.getMetaData().isAuthenticated) {
      // Only authenticated connections can perform 'approve', 'deny', 'revoke', 'update', or 'list' operations
      throw UnAuthenticatedException(
          'Cannot $operation enrollment without authentication');
    }
    if (operation != 'list' && verbParams == null) {
      // all operations except list require verb params
      throw IllegalArgumentException(
          'Verb params not provided for enroll $operation');
    }
    if (!atConnection.isRequestAllowed()) {
      // Throttle limit exceeded for enrollment requests
      throw AtThrottleLimitExceeded(
          'Enrollment requests have exceeded the limit within the specified time frame');
    }
    if ((operation == 'request' || operation == 'update') &&
        verbParams!['namespaces'] == null) {
      // 'request' and 'update' operations require 'namespaces' parameter
      throw IllegalArgumentException(
          'Invalid parameters received for Enrollment Verb. Namespace is required');
    }
    if (operation == 'update' &&
        atConnection.getMetaData().authType != AuthType.apkam) {
      // update operation requires an apkam authenticated connection
      throw UnAuthenticatedException(
          'Apkam authentication required to update enrollment');
    }
    if ((operation != 'request' || operation != 'list') &&
        verbParams!['enrollmentId'] == null) {
      // All operations except 'request' and 'list' require 'enrollmentId'
      throw IllegalArgumentException(
          'Required params not provided for enroll:$operation');
    }
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
  Future<EnrollVerbResponse> _handleEnrollmentRequest(enrollmentKey, verbParams,
      currentAtSign, operation, InboundConnection atConnection) async {
    EnrollVerbResponse enrollmentResponse = EnrollVerbResponse();

    // Ensure OTP is valid if connection is not authenticated
    if (!atConnection.getMetaData().isAuthenticated &&
        (verbParams['otp'] == null ||
            await OtpVerbHandler.cache.get(verbParams['otp'].toString()) ==
                null)) {
      throw IllegalArgumentException(
          'Invalid OTP. Cannot process enroll request');
    }

    EnrollParams enrollParams = EnrollParams.fromJson(verbParams);
    enrollmentResponse.data['enrollmentId'] = verbParams['enrollmentId'];
    logger.finer('Enrollment key: $enrollmentKey$currentAtSign');

    if (operation == 'update') {
      await processEnrollmentUpdate(
          enrollParams, currentAtSign, enrollmentResponse.response);
      
    }
    if (enrollmentResponse.response.isError) {
      return enrollmentResponse;
    }

    final EnrollDataStoreValue enrollmentValue = EnrollDataStoreValue(
        atConnection.getMetaData().sessionID!,
        enrollParams.appName!,
        enrollParams.deviceName!,
        enrollParams.apkamPublicKey!);
    enrollmentValue.namespaces = enrollParams.namespaces!;
    enrollmentValue.requestType = EnrollRequestType.newEnrollment;
    AtData? enrollData;

    if ((atConnection.getMetaData().authType != null) &&
        atConnection.getMetaData().authType == AuthType.cram) {
      // auto approve request from connection that is CRAM authenticated.
      await _autoApproveEnrollRequest(
          enrollParams, enrollmentValue, enrollData, currentAtSign);
      final inboundConnectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      inboundConnectionMetadata.enrollmentId = enrollParams.enrollmentId;
      enrollmentResponse.data['status'] = 'approved';
    } else {
      enrollmentValue.approval = EnrollApproval(EnrollStatus.pending.name);
      enrollmentResponse.data['status'] = 'pending';
      // Store notification and set TTL for pending enrollments
      await _storeNotification(enrollmentKey, enrollParams, currentAtSign);
      enrollData = AtData()
        ..data = jsonEncode(enrollmentValue.toJson())
        // Set TTL to the pending enrollments.
        // The enrollments will expire after configured
        // expiry limit, beyond which any action (approve/deny/revoke) on an
        // enrollment is forbidden
        ..metaData = (AtMetaData()..ttl = enrollmentExpiryInMills);
    }
    logger.finer('enrollData: $enrollData');
    await keyStore.put('$enrollmentKey$currentAtSign', enrollData,
        skipCommit: true);
    return enrollmentResponse;
  }

  Future<void> _autoApproveEnrollRequest(
      enrollParams, enrollmentValue, enrollData, currentAtsign) async {
    enrollParams.namespaces![enrollManageNamespace] = 'rw';
    enrollParams.namespaces![allNamespaces] = 'rw';
    enrollmentValue.approval = EnrollApproval(EnrollStatus.approved.name);
    // Store default encryption private key and self encryption key(both encrypted)
    // for future retrieval
    await _storeEncryptionKeys(enrollParams, currentAtsign);
    // store this apkam as default pkam public key for old clients
    // The keys with AT_PKAM_PUBLIC_KEY does not sync to client.
    await keyStore.put(AtConstants.atPkamPublicKey,
        AtData()..data = enrollParams.apkamPublicKey!);
    enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());
  }

  /// 1) Checks if the enrollment is already approved [only approved enrollments can be updated]
  ///
  /// 2) Ensures that the enrollment update is valid by checking the
  /// existing enrollDataStore value of the existing enrollment
  ///
  /// 3) Fetches data from existing enrollDataStoreValue and populates the [EnrollParams]
  @visibleForTesting
  Future<void> processEnrollmentUpdate(
      enrollParams, currentAtsign, response) async {
    // only process enrollment update if the existing enrollment is approved
    await ensureEnrollmentIsApproved(
        enrollParams.enrollmentId, currentAtsign, response);
    if(response.isError){
      return;
    }
    EnrollDataStoreValue? existingEnrollment;
    try {
      existingEnrollment = await getEnrollDataStoreValue(getEnrollmentKey(
          enrollParams.enrollmentId,
          currentAtsign: currentAtsign));
    } on KeyNotFoundException catch (e) {
      logger.finest('Could not fetch existing DataStoreValue for update| $e');
      throw AtInvalidEnrollmentException(
          'Enrollment_id: ${enrollParams.enrollmentId} is expired or invalid');
    }

    /// ToDo: should appName, deviceName be fetched from existing enrollDataStoreValue
    enrollParams.appName = existingEnrollment.appName;
    enrollParams.deviceName = existingEnrollment.deviceName;
    enrollParams.apkamPublicKey = existingEnrollment.apkamPublicKey;
  }

  /// Handles enrollment approve, deny and revoke requests.
  /// Retrieves enrollment details from keystore and updates the enrollment status based on [operation]
  /// If [operation] is approve, store the public key in public:appName.deviceName.pkam.__pkams.__public_keys
  /// and also store default encryption private key and default self encryption key in encrypted format.
  Future<EnrollVerbResponse> _updateEnrollmentApprovalStatus(
      enrollParams, currentAtSign, String? operation) async {
    logger.finer('EnrollmentId: ${enrollParams.enrollmentId}');
    String enrollmentKey = getEnrollmentKey(enrollParams.enrollmentId!);
    logger.finer(
        'Enrollment key: $enrollmentKey$currentAtSign | Enrollment operation: $operation');
    EnrollVerbResponse enrollmentResponse = EnrollVerbResponse();
    EnrollDataStoreValue? enrollDataStoreValue;
    bool isUpdate = false;
    try {
      enrollDataStoreValue =
          await getEnrollDataStoreValue('$enrollmentKey$currentAtSign');
    } on KeyNotFoundException {
      // KeyNotFound exception indicates an enrollment is expired or invalid
      throw AtInvalidEnrollmentException(
          'Enrollment_id: ${enrollParams.enrollmentId} is expired or invalid');
    }
    EnrollStatus enrollStatus =
        getEnrollStatusFromString(enrollDataStoreValue.approval!.state);

    if (operation == EnrollOperationEnum.approve.name &&
        await isEnrollmentUpdate(enrollParams.enrollmentId!, currentAtSign)) {
      isUpdate = true;
      enrollDataStoreValue.namespaces = await fetchUpdatedNamespaces(
          enrollParams.enrollmentId!, currentAtSign);
    }
    // Verifies whether the enrollment state matches the intended state
    // Assigns respective error codes and error messages in case of an invalid state
    _verifyEnrollmentState(operation, enrollStatus, enrollmentResponse.response,
        enrollParams.enrollmentId,
        isEnrollmentUpdate: isUpdate);
    if (enrollmentResponse.response.isError) {
      return enrollmentResponse;
    }

    enrollDataStoreValue.approval!.state = _getEnrollStatusEnum(operation).name;
    enrollmentResponse.data['status'] = _getEnrollStatusEnum(operation).name;
    enrollmentResponse.data['enrollmentId'] = enrollParams.enrollmentId;

    // If an enrollment is approved, we need the enrollment to be active
    // to subsequently revoke the enrollment. Hence reset TTL and
    // expiredAt on metadata.
    /* TODO: Currently TTL is reset on all the enrollments.
        However, if the enrollment state is denied or revoked,
        unless we wanted to display denied or revoked enrollments in the UI,
        we can let the TTL be, so that the enrollment will be deleted subsequently.*/
    await updateEnrollmentValueAndResetTTL(
        '$enrollmentKey$currentAtSign', enrollDataStoreValue);

    // when enrollment is approved store the apkamPublicKey of the enrollment
    // enrollment update does not change any public/private keys hence no change required
    if (operation == 'approve' && !isUpdate) {
      var apkamPublicKeyInKeyStore =
          'public:${enrollDataStoreValue.appName}.${enrollDataStoreValue.deviceName}.pkam.$pkamNamespace.__public_keys$currentAtSign';
      var valueJson = {'apkamPublicKey': enrollDataStoreValue.apkamPublicKey};
      var atData = AtData()..data = jsonEncode(valueJson);
      await keyStore.put(apkamPublicKeyInKeyStore, atData);
      await _storeEncryptionKeys(enrollParams, currentAtSign);
    }
    return enrollmentResponse;
  }

  /// Stores the encrypted default encryption private key in <enrollmentId>.default_enc_private_key.__manage@<atsign>
  /// and the encrypted self encryption key in <enrollmentId>.default_self_enc_key.__manage@<atsign>
  /// These keys will be stored only on server and will not be synced to the client
  /// Encrypted keys will be used later on by the approving app to send the keys to a new enrolling app
  Future<void> _storeEncryptionKeys(
      EnrollParams enrollParams, String atSign) async {
    var privKeyJson = {};
    privKeyJson['value'] = enrollParams.encryptedDefaultEncryptedPrivateKey;
    await keyStore.put(
        '${enrollParams.enrollmentId}.${AtConstants.defaultEncryptionPrivateKey}.$enrollManageNamespace$atSign',
        AtData()..data = jsonEncode(privKeyJson),
        skipCommit: true);
    var selfKeyJson = {};
    selfKeyJson['value'] = enrollParams.encryptedDefaultSelfEncryptionKey;
    await keyStore.put(
        '${enrollParams.enrollmentId}.${AtConstants.defaultSelfEncryptionKey}.$enrollManageNamespace$atSign',
        AtData()..data = jsonEncode(selfKeyJson),
        skipCommit: true);
  }

  EnrollStatus _getEnrollStatusEnum(String? enrollmentOperation) {
    enrollmentOperation = enrollmentOperation?.toLowerCase();
    final operationMap = {
      'approve': EnrollStatus.approved,
      'deny': EnrollStatus.denied,
      'revoke': EnrollStatus.revoked
    };
    return operationMap[enrollmentOperation] ?? EnrollStatus.pending;
  }

  /// Returns a Map where key is an enrollment key and value is a
  /// Map of "appName","deviceName" and "namespaces"
  Future<EnrollVerbResponse> _listEnrollments(
      AtConnection atConnection, String currentAtSign) async {
    EnrollVerbResponse enrollmentResponse = EnrollVerbResponse();
    Map<String, Map<String, dynamic>> enrollmentRequestsMap = {};
    String? enrollApprovalId =
        (atConnection.getMetaData() as InboundConnectionMetadata).enrollmentId;
    // If connection is authenticated via legacy PKAM, then enrollApprovalId is null.
    // Return all the enrollments.
    if (enrollApprovalId == null || enrollApprovalId.isEmpty) {
      await _fetchAllEnrollments(enrollmentRequestsMap);
      enrollmentResponse.data = enrollmentRequestsMap;
      return enrollmentResponse;
    }
    // If connection is authenticated via APKAM, then enrollApprovalId is populated,
    // check if the enrollment has access to __manage namespace.
    // If enrollApprovalId has access to __manage namespace, return all the enrollments,
    // Else return only the specific enrollment.
    final enrollmentKey =
        getEnrollmentKey(enrollApprovalId, currentAtsign: currentAtSign);
    EnrollDataStoreValue enrollDataStoreValue =
        await getEnrollDataStoreValue(enrollmentKey);

    if (_doesEnrollmentHaveManageNamespace(enrollDataStoreValue)) {
      await _fetchAllEnrollments(enrollmentRequestsMap);
    } else {
      if (enrollDataStoreValue.approval!.state != EnrollStatus.expired.name) {
        enrollmentRequestsMap[enrollmentKey] = {
          'appName': enrollDataStoreValue.appName,
          'deviceName': enrollDataStoreValue.deviceName,
          'namespace': enrollDataStoreValue.namespaces,
          'approval': enrollDataStoreValue.approval!.state
        };
      }
    }
    enrollmentResponse.data = enrollmentRequestsMap;
    return enrollmentResponse;
  }

  Future<void> _fetchAllEnrollments(
      Map<String, Map<String, dynamic>> enrollmentRequestsMap) async {
    // fetch all enrollments/enrollment-requests
    List<String> enrollmentKeysList =
        keyStore.getKeys(regex: newEnrollmentKeyPattern) as List<String>;
    // fetch enrollment update requests
    enrollmentKeysList.addAll(
        keyStore.getKeys(regex: updateEnrollmentKeyPattern) as List<String>);

    for (var enrollmentKey in enrollmentKeysList) {
      EnrollDataStoreValue enrollDataStoreValue;
      try {
        enrollDataStoreValue = await getEnrollDataStoreValue(enrollmentKey);
      } on KeyNotFoundException catch (e) {
        logger.finer('Error in fetching list of enrollment requests | $e)');
        continue;
      }
      if (enrollDataStoreValue.approval!.state != EnrollStatus.expired.name) {
        enrollmentRequestsMap[enrollmentKey] = {
          'appName': enrollDataStoreValue.appName,
          'deviceName': enrollDataStoreValue.deviceName,
          'namespace': enrollDataStoreValue.namespaces,
          'approval': enrollDataStoreValue.approval!.state
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
      logger.finer('notificationValue:$notificationValue');
      final atNotification = (AtNotificationBuilder()
            ..notification = key
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
    } on Exception catch (e, trace) {
      logger.severe(
          'Exception while storing notification key $key. Exception $e. Trace $trace');
    } on Error catch (e, trace) {
      logger.severe(
          'Error while storing notification key $key. Error $e. Trace $trace');
    }
  }

  /// Verifies whether the enrollment state matches the intended state.
  /// Populates respective errorCodes and errorMessages if the enrollment status
  /// is invalid for a certain operation
  void _verifyEnrollmentState(
      String? operation, EnrollStatus enrollStatus, response, enrollId,
      {bool isEnrollmentUpdate = false}) {
    if (isEnrollmentUpdate &&
        (operation != 'approve' && EnrollStatus.approved != enrollStatus)) {
      response.isError = true;
      response.errorCode = 'AT0030';
      response.errorMessage =
          'Enrollment_id: $enrollId is ${enrollStatus.name}. Only approved enrollments can be updated';
    }
    if (operation == 'approve' &&
        EnrollStatus.pending != enrollStatus &&
        !isEnrollmentUpdate) {
      response.isError = true;
      response.errorCode = 'AT0030';
      response.errorMessage =
          'Enrollment_id: $enrollId is ${enrollStatus.name}. Only pending enrollments can be approved';
    }
    if (operation == 'revoke' && EnrollStatus.approved != enrollStatus) {
      response.isError = true;
      response.errorCode = 'AT0030';
      response.errorMessage =
          'Enrollment_id: $enrollId is ${enrollStatus.name}. Only approved enrollments can be revoked';
    }
    if (enrollStatus == EnrollStatus.expired) {
      throw AtInvalidEnrollmentException(
          'Enrollment_id: $enrollId is expired or invalid');
    }
  }

  /// Inserts the enrollmentValue into the keystore for the given key
  /// resets the ttl and expiresAt for the enrollmentData
  @visibleForTesting
  Future<void> updateEnrollmentValueAndResetTTL(
      String enrollmentKey, EnrollDataStoreValue enrollDataStoreValue) async {
    // Fetch the existing data
    AtMetaData? enrollMetadata;
    try {
      enrollMetadata = await keyStore.getMeta(enrollmentKey);
    } on Exception catch (e) {
      logger.finer('Exception caught while fetching metadata | $e');
    }
    // Use an empty metadata object when existing metadata could not be fetched
    enrollMetadata ??= AtMetaData();
    // Update key with new data
    // only update ttl, expiresAt in metadata to preserve all the other valid data fields
    enrollMetadata.ttl = 0;
    enrollMetadata.expiresAt = null;
    await keyStore.put(
        enrollmentKey,
        AtData()
          ..data = jsonEncode(enrollDataStoreValue.toJson())
          ..metaData = enrollMetadata,
        skipCommit: true);
  }

  /// In case of an enrollment update, fetches updated namespaces from the
  /// enrollment update request and returns them
  @visibleForTesting
  Future<Map<String, String>> fetchUpdatedNamespaces(
      String enrollId, currentAtsign) async {
    String? enrollUpdateKey = getEnrollmentKey(enrollId,
        currentAtsign: currentAtsign, isSupplementaryKey: true);
    EnrollDataStoreValue supplementaryEnrollmentValue;
    try {
      supplementaryEnrollmentValue =
          await getEnrollDataStoreValue(enrollUpdateKey);
    } on KeyNotFoundException catch (e) {
      logger.finer('Could not fetch updated namespaces | $e');
      throw AtInvalidEnrollmentException(
          'update request for enrollment_id: $enrollId is expired or invalid');
    }
    return supplementaryEnrollmentValue.namespaces;
  }

  /// Verifies if the [enrollId] is an approved enrollment
  /// Returns true if approved enrollment
  /// If not an approved enrollment returns false and sets appropriate error responses
  @visibleForTesting
  Future<void> ensureEnrollmentIsApproved(enrollId, currentAtsign, response) async {
    String existingEnrollKey =
        getEnrollmentKey(enrollId, currentAtsign: currentAtsign);
    EnrollDataStoreValue? enrollmentValue;
    try {
      enrollmentValue = await getEnrollDataStoreValue(existingEnrollKey);
    } on KeyNotFoundException {
      throw AtInvalidEnrollmentException(
          'Cannot update enrollment_id: $enrollId. Enrollment is expired');
    }
    _verifyEnrollmentState(
        'approve',
        getEnrollStatusFromString(enrollmentValue.approval!.state),
        response,
        enrollId, isEnrollmentUpdate: true);
  }

  /// Checks if there is an existing enrollment update request with the given
  /// enrollment id
  ///
  /// Returns true if there is an supplementary enrollment key with the same
  /// enrollment id which has a current status of pending
  @visibleForTesting
  Future<bool> isEnrollmentUpdate(String enrollId, currentAtsign) async {
    String enrollUpdateKey = getEnrollmentKey(enrollId,
        currentAtsign: currentAtsign, isSupplementaryKey: true);
    EnrollDataStoreValue? enrollUpdateValue;
    try {
      enrollUpdateValue = await getEnrollDataStoreValue(enrollUpdateKey);
    } on KeyNotFoundException catch (e) {
      logger.finest('Exception when fetching enroll update value: $e');
      return false;
    }
    bool isValidUpdateRequest =
        enrollUpdateValue.approval!.state == EnrollStatus.pending.name;
    return isValidUpdateRequest;
  }

  /// Constructs the enrollmentKey based on given parameters
  @visibleForTesting
  String getEnrollmentKey(String enrollmentId,
      {bool isSupplementaryKey = false, String? currentAtsign}) {
    late String key;
    if (!isSupplementaryKey) {
      key = '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace';
    } else {
      key = '$enrollmentId.$updateEnrollmentKeyPattern.$enrollManageNamespace';
    }
    if (currentAtsign != null) {
      key = '$key$currentAtsign';
    }
    return key;
  }
}

class EnrollVerbResponse {
  Map<dynamic, dynamic> data = <dynamic, dynamic>{};
  Response response = Response();
}
