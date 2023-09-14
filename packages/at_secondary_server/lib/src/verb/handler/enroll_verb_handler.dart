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
    final responseJson = {};
    logger.finer('verb params: $verbParams');
    final operation = verbParams['operation'];
    final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    //Approve, deny, revoke or list enrollments only on authenticated connections
    if (operation != 'request' && !atConnection.getMetaData().isAuthenticated) {
      throw UnAuthenticatedException(
          'Cannot $operation enrollment without authentication');
    }
    EnrollParams? enrollVerbParams;
    try {
      // Ensure that enrollParams are present for all enroll operation
      // Exclude operation 'list' which does not have enrollParams
      if (verbParams[enrollParams] == null) {
        if (operation != 'list') {
          logger.severe(
              'Enroll params is empty | EnrollParams: ${verbParams[enrollParams]}');
          throw IllegalArgumentException('Enroll parameters not provided');
        }
      } else {
        enrollVerbParams =
            EnrollParams.fromJson(jsonDecode(verbParams[enrollParams]!));
      }
      switch (operation) {
        case 'request':
        case 'update':
          await _handleEnrollmentRequest(enrollVerbParams!, currentAtSign,
              operation, responseJson, atConnection);
          break;

        case 'approve':
        case 'deny':
        case 'revoke':
          await _handleEnrollmentPermissions(enrollVerbParams!, currentAtSign,
              operation, responseJson, response);
          break;
        case 'list':
          response.data =
              await _fetchEnrollmentRequests(atConnection, currentAtSign);
          return;
      }
    } catch (e, stackTrace) {
      logger.severe('Exception: $e\n$stackTrace');
      rethrow;
    }
    response.data = jsonEncode(responseJson);
    return;
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
  Future<void> _handleEnrollmentRequest(
      EnrollParams enrollParams,
      currentAtSign,
      operation,
      Map<dynamic, dynamic> responseJson,
      InboundConnection atConnection) async {
    String? otp = enrollParams.otp;
    await _validateConnectionAuth(otp, atConnection, operation);

    // assigns valid enrollmentId and enrollmentNamespaces to the enrollParams object
    // also constructs and returns an enrollment key
    String? enrollmentKey = _fetchEnrollmentDetails(operation, enrollParams);
    Map<String, String>? enrollNamespaces = enrollParams.namespaces;
    String? enrollId = enrollParams.enrollmentId;
    logger.finer('Enrollment key: $enrollmentKey$currentAtSign');
    responseJson['enrollmentId'] = enrollId;

    final enrollmentValue = EnrollDataStoreValue(
        atConnection.getMetaData().sessionID!,
        enrollParams.appName!,
        enrollParams.deviceName!,
        enrollParams.apkamPublicKey!);
    enrollmentValue.namespaces = enrollNamespaces!;
    enrollmentValue.requestType = EnrollRequestType.newEnrollment;

    AtData enrollData;
    if (atConnection.getMetaData().authType != null &&
        atConnection.getMetaData().authType == AuthType.cram) {
      // auto approve request from connection that is CRAM authenticated.
      enrollNamespaces[enrollManageNamespace] = 'rw';
      enrollNamespaces[allNamespaces] = 'rw';
      enrollmentValue.approval = EnrollApproval(EnrollStatus.approved.name);
      responseJson['status'] = 'approved';
      final inboundConnectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
      inboundConnectionMetadata.enrollmentId = enrollId;
      // Store default encryption private key and self encryption key(both encrypted)
      // for future retrieval
      await _storeEncryptionKeys(enrollId!, enrollParams, currentAtSign);
      // store this apkam as default pkam public key for old clients
      // The keys with AT_PKAM_PUBLIC_KEY does not sync to client.
      await keyStore.put(
          AT_PKAM_PUBLIC_KEY, AtData()..data = enrollParams.apkamPublicKey!);
      enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());
    } else {
      if(
      operation == 'update' && await _isApprovedEnrollment(enrollId)){
        throw AtEnrollmentException('cannot update unapproved enrollment_id: $enrollId');
      }
      enrollmentValue.approval = EnrollApproval(EnrollStatus.pending.name);
      responseJson['status'] = 'pending';
      await _storeNotification(enrollmentKey!, enrollParams, currentAtSign);
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
  }

  /// Handles enrollment approve, deny and revoke requests.
  /// Retrieves enrollment details from keystore and updates the enrollment status based on [operation]
  /// If [operation] is approve, store the public key in public:appName.deviceName.pkam.__pkams.__public_keys
  /// and also store default encryption private key and default self encryption key in encrypted format.
  Future<void> _handleEnrollmentPermissions(
      EnrollParams enrollParams,
      currentAtSign,
      String? operation,
      Map<dynamic, dynamic> responseJson,
      Response response) async {
    final enrollmentIdFromParams = enrollParams.enrollmentId;
    String enrollmentKey =
        '$enrollmentIdFromParams.$newEnrollmentKeyPattern.$enrollManageNamespace';
    logger.finer(
        'Enrollment key: $enrollmentKey$currentAtSign | Enrollment operation: $operation');
    EnrollDataStoreValue? enrollDataStoreValue;
    EnrollStatus? enrollStatus;
    // Fetch and returns enrollment data from the keystore.
    try {
      enrollDataStoreValue =
          await getEnrollDataStoreValue('$enrollmentKey$currentAtSign');
    } on KeyNotFoundException {
      // When an enrollment key is expired or invalid
      enrollStatus = EnrollStatus.expired;
    }
    enrollStatus ??=
        getEnrollStatusFromString(enrollDataStoreValue!.approval!.state);

    if (EnrollStatus.expired == enrollStatus) {
      response.isError = true;
      response.errorCode = 'AT0028';
      response.errorMessage =
          'enrollment_id: $enrollmentIdFromParams is expired or invalid';
      return;
    }
    // If the current operation is approve, but the enrollment is already approved
    // This case is an enrollment access update operation
    if (operation == EnrollOperationEnum.approve.name &&
        await _isApprovedEnrollment(enrollmentIdFromParams,
            enrollmentValue: enrollDataStoreValue)) {
      await _updateEnrollmentAccess(
          enrollmentIdFromParams!, enrollDataStoreValue!);
    } else {
      // Verifies whether the enrollment state matches the intended state
      // Throws AtEnrollmentException, if the enrollment state is different from
      // the intended state
      _verifyEnrollmentState(operation, enrollStatus);
      // This check is in the else block because it would throw an exception for update operations
    }

    enrollDataStoreValue!.approval!.state =
        _getEnrollStatusEnum(operation).name;
    responseJson['status'] = _getEnrollStatusEnum(operation).name;

    // If an enrollment is approved, we need the enrollment to be active
    // to subsequently revoke the enrollment. Hence reset TTL and
    // expiredAt on metadata.
    /* TODO: Currently TTL is reset on all the enrollments.
        However, if the enrollment state is denied or revoked,
        unless we wanted to display denied or revoked enrollments in the UI,
        we can let the TTL be, so that the enrollment will be deleted subsequently.*/
    await _updateEnrollmentValueAndResetTTL(
        '$enrollmentKey$currentAtSign', enrollDataStoreValue);
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

  Future<void> _updateEnrollmentAccess(
      String enrollId, EnrollDataStoreValue existingEnrollmentValue) async {
    String? supplementaryEnrollKey =
        '$enrollId.$updateEnrollmentKeyPattern.$enrollManageNamespace';
    EnrollDataStoreValue supplementaryEnrollmentValue =
        await getEnrollDataStoreValue(supplementaryEnrollKey);
    Map<String, String> updatedNamespaces =
        supplementaryEnrollmentValue.namespaces;
    // update existing dataStoreValue with new namespaces from the supplementary key
    existingEnrollmentValue.namespaces = updatedNamespaces;
  }

  /// Stores the encrypted default encryption private key in <enrollmentId>.default_enc_private_key.__manage@<atsign>
  /// and the encrypted self encryption key in <enrollmentId>.default_self_enc_key.__manage@<atsign>
  /// These keys will be stored only on server and will not be synced to the client
  /// Encrypted keys will be used later on by the approving app to send the keys to a new enrolling app
  Future<void> _storeEncryptionKeys(
      String newEnrollmentId, EnrollParams enrollParams, String atSign) async {
    var privKeyJson = {};
    privKeyJson['value'] = enrollParams.encryptedDefaultEncryptedPrivateKey;
    await keyStore.put(
        '$newEnrollmentId.$defaultEncryptionPrivateKey.$enrollManageNamespace$atSign',
        AtData()..data = jsonEncode(privKeyJson),
        skipCommit: true);
    var selfKeyJson = {};
    selfKeyJson['value'] = enrollParams.encryptedDefaultSelfEncryptionKey;
    await keyStore.put(
        '$newEnrollmentId.$defaultSelfEncryptionKey.$enrollManageNamespace$atSign',
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
  Future<String> _fetchEnrollmentRequests(
      AtConnection atConnection, String currentAtSign) async {
    Map<String, Map<String, dynamic>> enrollmentRequestsMap = {};
    String? enrollApprovalId =
        (atConnection.getMetaData() as InboundConnectionMetadata).enrollmentId;
    List<String> enrollmentKeysList =
        keyStore.getKeys(regex: newEnrollmentKeyPattern) as List<String>;
    // If connection is authenticated via legacy PKAM, then enrollApprovalId is null.
    // Return all the enrollments.
    if (enrollApprovalId == null || enrollApprovalId.isEmpty) {
      await _fetchAllEnrollments(enrollmentKeysList, enrollmentRequestsMap);
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
      await _fetchAllEnrollments(enrollmentKeysList, enrollmentRequestsMap);
    } else {
      if (enrollDataStoreValue.approval!.state != EnrollStatus.expired.name) {
        enrollmentRequestsMap[enrollmentKey] = {
          'appName': enrollDataStoreValue.appName,
          'deviceName': enrollDataStoreValue.deviceName,
          'namespace': enrollDataStoreValue.namespaces
        };
      }
    }
    return jsonEncode(enrollmentRequestsMap);
  }

  Future<void> _fetchAllEnrollments(List<String> enrollmentKeysList,
      Map<String, Map<String, dynamic>> enrollmentRequestsMap) async {
    for (var enrollmentKey in enrollmentKeysList) {
      EnrollDataStoreValue enrollDataStoreValue =
          await getEnrollDataStoreValue(enrollmentKey);
      if (enrollDataStoreValue.approval!.state != EnrollStatus.expired.name) {
        enrollmentRequestsMap[enrollmentKey] = {
          'appName': enrollDataStoreValue.appName,
          'deviceName': enrollDataStoreValue.deviceName,
          'namespace': enrollDataStoreValue.namespaces
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
      notificationValue[apkamEncryptedSymmetricKey] =
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
          'Exception while storing notification key $enrollmentId. Exception $e. Trace $trace');
    } on Error catch (e, trace) {
      logger.severe(
          'Error while storing notification key $enrollmentId. Error $e. Trace $trace');
    }
  }

  /// Verifies whether the enrollment state matches the intended state.
  /// Throws AtEnrollmentException: If the enrollment state is different
  /// from the intended state.
  void _verifyEnrollmentState(String? operation, EnrollStatus enrollStatus) {
    /// ToDo: should error codes be set instead of exceptions?
    if (operation == 'approve' && EnrollStatus.pending != enrollStatus) {
      throw AtEnrollmentException(
          'Cannot approve a ${enrollStatus.name} enrollment. Only pending enrollments can be approved');
    }
    if (operation == 'revoke' && EnrollStatus.approved != enrollStatus) {
      throw AtEnrollmentException(
          'Cannot revoke a ${enrollStatus.name} enrollment. Only approved enrollments can be revoked');
    }
    if (operation == 'update' && EnrollStatus.approved != enrollStatus) {
      throw AtEnrollmentException(
          'Cannot update a ${enrollStatus.name} enrollment. Only approved enrollments can be updated');
    }
  }

  Future<void> _updateEnrollmentValueAndResetTTL(
      String enrollmentKey, EnrollDataStoreValue enrollDataStoreValue) async {
    // Fetch the existing data
    AtMetaData? enrollMetaData = await keyStore.getMeta(enrollmentKey);
    // Update key with new data
    // only update ttl, expiresAt in metadata to preserve all the other valid data fields
    enrollMetaData?.ttl = 0;
    enrollMetaData?.expiresAt = null;
    await keyStore.put(
        enrollmentKey,
        AtData()
          ..data = jsonEncode(enrollDataStoreValue.toJson())
          ..metaData = enrollMetaData,
        skipCommit: true);
  }

  Future<bool> _isApprovedEnrollment(enrollId,
      {EnrollDataStoreValue? enrollmentValue}) async {
    String existingEnrollKey =
        '$enrollId.$newEnrollmentKeyPattern.$enrollManageNamespace';
    try {
      enrollmentValue ??= await getEnrollDataStoreValue(existingEnrollKey);
    } on KeyNotFoundException {
      throw AtEnrollmentException(
          'Cannot update a ${EnrollStatus.expired} enrollment. Only approved enrollments can be updated');
    }

    return enrollmentValue.approval!.state == EnrollStatus.approved.name;
  }

  String? _fetchEnrollmentDetails(operation, enrollParams) {
    String? enrollmentKey;
    switch (operation) {
      case 'request':
        enrollParams.namespaces ??= {};
        enrollParams.enrollmentId = Uuid().v4();
        enrollmentKey =
            '${enrollParams.enrollmentId}.$newEnrollmentKeyPattern.$enrollManageNamespace';
        break;
      case 'update':
        if (enrollParams.enrollmentId == null ||
            enrollParams.namespaces == null) {
          logger.info(
              'Invalid \'enroll:update\' params: enrollId: ${enrollParams.enrollmentId} enrollNamespace: ${enrollParams.namespaces}');
          throw IllegalArgumentException(
              'Invalid parameters received for Enrollment Update');
        }
        enrollmentKey =
            '${enrollParams.enrollmentId}.$updateEnrollmentKeyPattern.$enrollManageNamespace';
        break;
      default:
        throw IllegalArgumentException('Invalid operation: \'$operation\'');
    }
    return enrollmentKey;
  }

  Future<void> _validateConnectionAuth(otp, atConnection, operation) async {
    if (operation == 'update' &&
        atConnection.getMetaData().authType != AuthType.apkam) {
      throw AtEnrollmentException(
          'Apkam authentication required to update enrollment');
    }
    if (!atConnection.getMetaData().isAuthenticated) {
      if (otp == null ||
          (await OtpVerbHandler.cache.get(otp.toString()) == null)) {
        throw AtEnrollmentException(
            'invalid otp. Cannot process enroll request');
      }
    }
  }
}
