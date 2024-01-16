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
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'abstract_verb_handler.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

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

  EnrollVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
    if (operation != 'request' && !atConnection.getMetaData().isAuthenticated) {
      throw UnAuthenticatedException(
          'Cannot $operation enrollment without authentication');
    }
    EnrollParams? enrollVerbParams;
    try {
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
      switch (operation) {
        case 'request':
          await _handleEnrollmentRequest(
              enrollVerbParams!, currentAtSign, responseJson, atConnection);
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
    if (atConnection.getMetaData().isAuthenticated == false) {
      var isValid = await isOTPValid(enrollParams.otp);
      if (!isValid) {
        _lastInvalidOtpReceivedInMills =
            DateTime.now().toUtc().millisecondsSinceEpoch;
        await Future.delayed(
            Duration(milliseconds: getDelayIntervalInMilliseconds()));
        throw AtEnrollmentException(
            'invalid otp. Cannot process enroll request');
      }
    }

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
        atConnection.getMetaData().sessionID!,
        enrollParams.appName!,
        enrollParams.deviceName!,
        enrollParams.apkamPublicKey!);
    enrollmentValue.namespaces = enrollNamespaces;
    enrollmentValue.requestType = EnrollRequestType.newEnrollment;
    AtData enrollData;
    if (atConnection.getMetaData().authType != null &&
        atConnection.getMetaData().authType == AuthType.cram) {
      // auto approve request from connection that is CRAM authenticated.
      enrollNamespaces[enrollManageNamespace] = 'rw';
      enrollNamespaces[allNamespaces] = 'rw';
      enrollmentValue.approval = EnrollApproval(EnrollmentStatus.approved.name);
      responseJson['status'] = 'approved';
      final inboundConnectionMetadata =
          atConnection.getMetaData() as InboundConnectionMetadata;
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
    _verifyEnrollmentStateBeforeAction(operation, enrollStatus);
    enrollDataStoreValue!.approval!.state =
        _getEnrollStatusEnum(operation).name;
    responseJson['status'] = _getEnrollStatusEnum(operation).name;

    // If an enrollment is approved, we need the enrollment to be active
    // to subsequently revoke the enrollment. Hence reset TTL and
    // expiredAt on metadata.
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

  /// Stores the encrypted default encryption private key in <enrollmentId>.default_enc_private_key.__manage@<atsign>
  /// and the encrypted self encryption key in <enrollmentId>.default_self_enc_key.__manage@<atsign>
  /// These keys will be stored only on server and will not be synced to the client
  /// Encrypted keys will be used later on by the approving app to send the keys to a new enrolling app
  Future<void> _storeEncryptionKeys(
      String newEnrollmentId, EnrollParams enrollParams, String atSign) async {
    var privKeyJson = {};
    privKeyJson['value'] = enrollParams.encryptedDefaultEncryptionPrivateKey;
    await keyStore.put(
        '$newEnrollmentId.${AtConstants.defaultEncryptionPrivateKey}.$enrollManageNamespace$atSign',
        AtData()..data = jsonEncode(privKeyJson),
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
      'revoke': EnrollmentStatus.revoked
    };

    return operationMap[enrollmentOperation] ?? EnrollmentStatus.pending;
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
      if (enrollDataStoreValue.approval!.state !=
          EnrollmentStatus.expired.name) {
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
      if (enrollDataStoreValue.approval!.state !=
          EnrollmentStatus.expired.name) {
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
          'Exception while storing notification key ${AtConstants.enrollmentId}. Exception $e. Trace $trace');
    } on Error catch (e, trace) {
      logger.severe(
          'Error while storing notification key ${AtConstants.enrollmentId}. Error $e. Trace $trace');
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

  /// NOT a part of API. Used for unit tests
  @visibleForTesting
  int getEnrollmentResponseDelayInMilliseconds() {
    return delayForInvalidOTPSeries.last;
  }
}
