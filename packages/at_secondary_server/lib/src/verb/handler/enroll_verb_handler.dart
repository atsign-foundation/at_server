import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/totp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import '../../server/at_secondary_config.dart';
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
  Duration enrollmentExpiry = Duration(hours: AtSecondaryConfig.enrollmentExpiryInHours);

  int enrollmentKeyTtl =
      Duration(days: AtSecondaryConfig.enrollmentKeyTtlInDays).inMilliseconds;

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
    try {
      EnrollParams? enrollVerbParams;
      if (verbParams[enrollParams] != null) {
        enrollVerbParams =
            EnrollParams.fromJson(jsonDecode(verbParams[enrollParams]!));
      }
      switch (operation) {
        case 'request':
          await _handleEnrollmentRequest(
              enrollVerbParams!, currentAtSign, responseJson, atConnection);
          break;

        case 'approve':
        case 'deny':
        case 'revoke':
          await _handleEnrollmentPermissions(
              enrollVerbParams!, currentAtSign, operation, responseJson);
          break;

        case 'list':
          response.data =
              await _fetchEnrollmentRequests(atConnection, currentAtSign);
          return;
      }
    } catch (e, stackTrace) {
      response.isError = true;
      response.errorMessage = e.toString();
      responseJson['status'] = 'exception';
      responseJson['reason'] = e.toString();
      logger.severe('Exception: $e\n$stackTrace');
      rethrow;
    }
    if (responseJson['status'] == EnrollStatus.expired.name) {
      response.isError = true;
      response.errorMessage = 'enroll id: $enrollmentId is expired';
      response.errorCode = 'AT0028';
      return;
    }
    response.data = jsonEncode(responseJson);
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
      Map<dynamic, dynamic> responseJson,
      InboundConnection atConnection) async {
    if (!atConnection.getMetaData().isAuthenticated) {
      var totp = enrollParams.totp;
      if (totp == null ||
          (await TotpVerbHandler.cache.get(totp.toString()) == null)) {
        throw AtEnrollmentException(
            'invalid totp. Cannot process enroll request');
      }
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
    // The enrollments will expire after configured
    // expiry limit, beyond which any action (approve/deny/revoke) on an
    // enrollment is forbidden
    enrollmentValue.expiresAt = DateTime.now().toUtc().add(enrollmentExpiry);
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
      inboundConnectionMetadata.enrollmentId = newEnrollmentId;
      // Store default encryption private key and self encryption key(both encrypted)
      // for future retrieval
      await _storeEncryptionKeys(newEnrollmentId, enrollParams, currentAtSign);
      // store this apkam as default pkam public key for old clients
      // The keys with AT_PKAM_PUBLIC_KEY does not sync to client.
      await keyStore.put(
          AT_PKAM_PUBLIC_KEY, AtData()..data = enrollParams.apkamPublicKey!);
      enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());
    } else {
      enrollmentValue.approval = EnrollApproval(EnrollStatus.pending.name);
      await _storeNotification(key, enrollParams, currentAtSign);
      responseJson['status'] = 'pending';
      enrollData = AtData()
        ..data = jsonEncode(enrollmentValue.toJson())
        // Set TTL to the pending enrollments
        // This configures when an enrollment key is deleted
        ..metaData = (AtMetaData()..ttl = enrollmentKeyTtl);
    }
    logger.finer('enrollData: $enrollData');
    await keyStore.put('$key$currentAtSign', enrollData, skipCommit: true);
  }

  /// Handles enrollment approve, deny and revoke requests.
  /// Retrieves enrollment details from keystore and updates the enrollment status based on [operation]
  /// If [operation] is approve, store the public key in public:appName.deviceName.pkam.__pkams.__public_keys
  /// and also store default encryption private key and default self encryption key in encrypted format.
  Future<void> _handleEnrollmentPermissions(
      EnrollParams enrollParams,
      currentAtSign,
      String? operation,
      Map<dynamic, dynamic> responseJson) async {
    final enrollmentIdFromParams = enrollParams.enrollmentId;
    String enrollmentKey =
        '$enrollmentIdFromParams.$newEnrollmentKeyPattern.$enrollManageNamespace';
    logger.finer(
        'Enrollment key: $enrollmentKey$currentAtSign | Enrollment operation: $operation');
    // Fetch and returns enrollment data from the keystore.
    // Throw AtEnrollmentException, IF
    //   1. Enrollment key is not present in keystore
    //   2. Enrollment key is not active
    AtData enrollData = await _fetchEnrollmentDataFromKeyStore(
        enrollmentKey, currentAtSign, enrollmentIdFromParams);

    EnrollDataStoreValue enrollDataStoreValue =
        EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data!));

    if (enrollDataStoreValue.approval!.state == EnrollStatus.expired.name) {
      // case 1: enrollment expired and the enrollment keystore value is updated to expired
      responseJson['status'] = EnrollStatus.expired.name;
      responseJson['enrollmentId'] = enrollmentIdFromParams;
      return;
    } else if(enrollDataStoreValue.isExpired()){
      // case 2: enrollment expired and the enrollment keystore value is NOT updated to expired
      enrollDataStoreValue.approval!.state = EnrollStatus.expired.name;
      // update keystore value with approval state as expired
      await _updateEnrollmentKey('$enrollmentKey$currentAtSign',
          enrollDataStoreValue, enrollData.metaData);
      responseJson['status'] = EnrollStatus.expired.name;
      responseJson['enrollmentId'] = enrollmentIdFromParams;
      return;
    }
    // Verifies whether the enrollment state matches the intended state
    // Throws AtEnrollmentException, if the enrollment state is different from
    // the intended state
    _verifyEnrollmentStateBeforeAction(operation, enrollDataStoreValue);
    enrollDataStoreValue.approval!.state = _getEnrollStatusEnum(operation).name;
    responseJson['status'] = _getEnrollStatusEnum(operation).name;

    // If an enrollment is approved, we need the enrollment to be active
    // to subsequently revoke the enrollment. Hence reset TTL and
    // expiredAt on metadata.
    /* TODO: Currently TTL is reset on all the enrollments.
        However, if the enrollment state is denied or revoked,
        unless we wanted to display denied or revoked enrollments in the UI,
        we can let the TTL be, so that the enrollment will be deleted subsequently.*/
    await _updateEnrollmentKey(
        '$enrollmentKey$currentAtSign',
        enrollDataStoreValue,
        enrollData.metaData
          ?..ttl = 0
          ..expiresAt = null);
    // when enrollment is approved store the apkamPublicKey of the enrollment
    if (operation == 'approve') {
      var apkamPublicKeyInKeyStore =
          'public:${enrollDataStoreValue.appName}.${enrollDataStoreValue.deviceName}.pkam.$pkamNamespace.__public_keys$currentAtSign';
      var valueJson = {};
      valueJson[apkamPublicKey] = enrollDataStoreValue.apkamPublicKey;
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
      if (!(enrollDataStoreValue.approval!.state == 'expired')) {
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
      if (enrollDataStoreValue.expiresAt != null &&
          DateTime.now().toUtc().isAfter(enrollDataStoreValue.expiresAt!)) {
        continue;
      }
      enrollmentRequestsMap[enrollmentKey] = {
        'appName': enrollDataStoreValue.appName,
        'deviceName': enrollDataStoreValue.deviceName,
        'namespace': enrollDataStoreValue.namespaces
      };
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

  Future<AtData> _fetchEnrollmentDataFromKeyStore(
      String enrollmentKey, currentAtSign, String? enrollmentId) async {
    AtData enrollData;
    // KeyStore.get will not return null. If the value is null, keyStore.get
    // throws KeyNotFoundException.
    // So, enrollData will NOT be null.
    try {
      enrollData = await keyStore.get('$enrollmentKey$currentAtSign');
    } on KeyNotFoundException {
      throw AtEnrollmentException(
          'enrollment id: $enrollmentId not found in keystore');
    }

    // If enrollment is not active, throw AtEnrollmentException
    if (!SecondaryUtil.isActiveKey(enrollData)) {
      throw AtEnrollmentException('The enrollment $enrollmentId is expired');
    }
    return enrollData;
  }

  /// Verifies whether the enrollment state matches the intended state.
  /// Throws AtEnrollmentException: If the enrollment state is different
  /// from the intended state.
  void _verifyEnrollmentStateBeforeAction(
      String? operation, EnrollDataStoreValue enrollDataStoreValue) {
    if (operation == 'approve' &&
        enrollDataStoreValue.approval!.state != EnrollStatus.pending.name) {
      throw AtEnrollmentException(
          'Cannot approve a ${enrollDataStoreValue.approval!.state} enrollment. Only pending enrollments can be approved');
    }
    if (operation == 'revoke' &&
        enrollDataStoreValue.approval!.state != EnrollStatus.approved.name) {
      throw AtEnrollmentException(
          'Cannot revoke a ${enrollDataStoreValue.approval!.state} enrollment. Only approved enrollments can be revoked');
    }
  }

  Future<void> _updateEnrollmentKey(String key,
      EnrollDataStoreValue enrollDataStoreValue, var metaData) async {
    await keyStore.put(
        key,
        AtData()
          ..data = jsonEncode(enrollDataStoreValue.toJson())
          ..metaData = metaData,
        skipCommit: true);
  }
}
