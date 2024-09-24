import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart' as handler_util;
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';

final String paramFullCommandAsReceived = 'FullCommandAsReceived';

abstract class AbstractVerbHandler implements VerbHandler {
  final SecondaryKeyStore keyStore;

  late AtSignLogger logger;
  ResponseHandlerManager responseManager =
      DefaultResponseHandlerManager.getInstance();

  AbstractVerbHandler(this.keyStore) {
    logger = AtSignLogger(runtimeType.toString());
  }

  /// Parses a given command against a corresponding verb syntax
  /// @returns  Map containing  key(group name from syntax)-value from the command
  HashMap<String, String?> parse(String command) {
    try {
      return handler_util.getVerbParam(getVerb().syntax(), command);
    } on InvalidSyntaxException {
      throw InvalidSyntaxException('Invalid syntax. ${getVerb().usage()}');
    }
  }

  @override
  Future<void> process(String command, InboundConnection atConnection) async {
    var response = await processInternal(command, atConnection);
    var responseHandler = responseManager.getResponseHandler(getVerb());
    await responseHandler.process(atConnection, response);
  }

  Future<Response> processInternal(
      String command, InboundConnection atConnection) async {
    var response = Response();
    var atConnectionMetadata = atConnection.metaData;
    if (getVerb().requiresAuth() && !atConnectionMetadata.isAuthenticated) {
      throw UnAuthenticatedException('Command cannot be executed without auth');
    }
    // This check verifies whether the enrollment is active on the already APKAM authenticated existing connection
    // and terminates if the enrollment is expired.
    // At this stage, the enrollmentId is not set to the InboundConnectionMetadata for the new connections.
    // This will not terminate an un-authenticated connection when attempting to execute a PKAM verb with an expired enrollmentId.
    (bool, Response) isEnrollmentActive =
        await _verifyIfEnrollmentIsActive(response, atConnectionMetadata);
    if (isEnrollmentActive.$1 == false) {
      await atConnection.close();
      return isEnrollmentActive.$2;
    }
    try {
      // Parse the command
      var verbParams = parse(command);
      // TODO This is not ideal. Would be better to make it so that processVerb takes command as an argument also.
      verbParams[paramFullCommandAsReceived] = command;
      // Syntax is valid. Process the verb now.
      await processVerb(response, verbParams, atConnection);
      if (this is SyncProgressiveVerbHandler) {
        final verbHandler = this as SyncProgressiveVerbHandler;
        verbHandler.logResponse(response.data!);
      } else {
        logger.finer(
            'Verb : ${getVerb().name()}  Response: ${response.toString()}');
      }
      return response;
    } on Exception {
      rethrow;
    }
  }

  /// When authenticated with the APKAM keys, checks if the enrollment is active.
  /// Returns true if the enrollment is active; otherwise, returns false.
  Future<(bool, Response)> _verifyIfEnrollmentIsActive(
      Response response, AtConnectionMetaData atConnectionMetadata) async {
    // When authenticated with legacy keys, enrollment id is null. APKAM expiry does not
    // apply to such connections. Therefore, return true.
    if ((atConnectionMetadata as InboundConnectionMetadata).enrollmentId ==
        null) {
      logger.finest(
          "Enrollment id is not found. Returning true from _verifyIfEnrollmentIsActive");
      return (true, response);
    }
    try {
      EnrollDataStoreValue enrollDataStoreValue =
          await AtSecondaryServerImpl.getInstance()
              .enrollmentManager
              .get(atConnectionMetadata.enrollmentId!);
      // If the enrollment status is expired, then the enrollment is not active. Return false.
      if (enrollDataStoreValue.approval?.state ==
          EnrollmentStatus.expired.name) {
        logger.severe(
            'The enrollment id: ${atConnectionMetadata.enrollmentId} is expired. Closing the connection');
        response
          ..isError = true
          ..errorCode = 'AT0028'
          ..errorMessage =
              'The enrollment id: ${(atConnectionMetadata).enrollmentId} is expired. Closing the connection';
        return (false, response);
      }
      // The expired enrollments are removed from the keystore. In such cases, KeyNotFoundException is
      // thrown. Return false.
    } on KeyNotFoundException {
      logger.severe(
          'The enrollment id: ${atConnectionMetadata.enrollmentId} is expired. Closing the connection');
      response
        ..isError = true
        ..errorCode = 'AT0028'
        ..errorMessage =
            'The enrollment id: ${(atConnectionMetadata).enrollmentId} is expired. Closing the connection';
      return (false, response);
    }
    logger.finest(
        "Enrollment id ${atConnectionMetadata.enrollmentId} is active. Returning true from _verifyIfEnrollmentIsActive");
    return (true, response);
  }

  /// Return the instance of the current verb
  ///@return instance of [Verb]
  Verb getVerb();

  /// Process the given command using verbParam and requesting atConnection. Sets the data in response.
  ///@param response - response of the command
  ///@param verbParams - contains key-value mapping of groups names from verb syntax
  ///@param atConnection - Requesting connection
  Future<void> processVerb(Response response,
      HashMap<String, String?> verbParams, InboundConnection atConnection);

  /// Fetch for an enrollment key in the keystore.
  /// If key is available returns [EnrollDataStoreValue],
  /// else throws [KeyNotFoundException]
  Future<EnrollDataStoreValue> getEnrollDataStoreValue(
      String enrollmentKey) async {
    try {
      AtData enrollData = await keyStore.get(enrollmentKey);
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue.fromJson(jsonDecode(enrollData.data!));
      if (!SecondaryUtil.isActiveKey(enrollData)) {
        enrollDataStoreValue.approval?.state = EnrollmentStatus.expired.name;
      }
      return enrollDataStoreValue;
    } on KeyNotFoundException {
      logger.severe('$enrollmentKey does not exist in the keystore');
      rethrow;
    }
  }

  /// Verifies whether the current connection has permission to
  /// modify, delete, or retrieve the data in a given namespace.
  ///
  /// The connection's enrollment should be in an approved state.
  ///
  /// To execute a data retrieval (lookup or local lookup), the connection
  /// must have "r" or "rw" (read / read-write) access for the namespace.
  ///
  /// For update or delete, the connection must have "rw" (read-write) access.
  ///
  /// Returns true if
  /// - EITHER the connection has no enrollment ID (i.e. it was the first enrolled
  ///   app)
  /// - OR the connection has the required read or read-write
  ///   permissions to execute lookup/local-lookup or update/delete operations
  ///   respectively
  ///
  /// The connection will be deemed not to have permission if any of the
  /// following are true:
  ///  - the enrollment key is not present in the keystore.
  ///  - the enrollment is not in "approved" state
  ///  - the connection has no permissions for this namespace
  ///  - the connection has insufficient permission for this namespace
  ///    (for example, has "r" but needs "rw" for a delete operation)
  ///  - If enrollment is a part of "global" or "manage" namespace
  ///  - the connection does not have access to * namespace and key has no namespace
  /// Use [namespace] if passed, otherwise retrieve namespace from [atKey]. Return false if no [namespace] or [atKey] is set.
  Future<bool> isAuthorized(InboundConnectionMetadata inboundConnectionMetadata,
      {String? atKey,
      String? namespace,
      String enrolledNamespaceAccess = '',
      String operation = ''}) async {
    // If legacy PKAM (full permissions) or is a reserved key (to which all
    // authenticated connections have access) then return true
    if (inboundConnectionMetadata.enrollmentId == null ||
        _isReservedKey(atKey)) {
      return true;
    }

    EnrollDataStoreValue enrollDataStoreValue;

    try {
      enrollDataStoreValue = await AtSecondaryServerImpl.getInstance()
          .enrollmentManager
          .get(inboundConnectionMetadata.enrollmentId!);
    } on KeyNotFoundException {
      logger.shout(
          'Could not retrieve enrollment data for ${inboundConnectionMetadata.enrollmentId}');
      return false;
    }

    bool isValid = _applyEnrollmentValidations(
        enrollDataStoreValue, operation, atKey, namespace);
    if (!isValid) {
      return isValid;
    }

    // If namespace is null or empty, fetch namespace from AtKey.
    String keyWithNamespace = '';
    if ((namespace == null || namespace.isEmpty) && atKey != null) {
      AtKey atKeyObj = AtKey.fromString(atKey);
      namespace = atKeyObj.namespace;
      keyWithNamespace = '${atKeyObj.key}.$namespace';
    }

    // Checks for namespace authorisation
    // In the authorizedNamespace, the first parameter represents the namespace and second parameter represents the
    // access of the namespace.
    (String, String?) authorizedNamespace = _checkForNamespaceAuthorization(
        enrollDataStoreValue, namespace, keyWithNamespace);

    // "authorizedNamespace.$1" represents the namespace and "authorizedNamespace.$2" represents
    // the access of the namespace.
    if (authorizedNamespace.$1.isEmpty ||
        (authorizedNamespace.$2 == null || authorizedNamespace.$2!.isEmpty)) {
      return false;
    }

    // Only spp and enroll operations are allowed to access
    // the enrollManageNamespace
    // Prevents update, delete or any other operations on the enrollment key
    if (authorizedNamespace.$1 == enrollManageNamespace) {
      return (getVerb() is Otp || getVerb() is Enroll || getVerb() is Monitor)
          ? (authorizedNamespace.$2 == 'r' || authorizedNamespace.$2 == 'rw')
          : false;
    }
    return checkEnrollmentNamespaceAccess(authorizedNamespace.$2!,
        enrolledNamespaceAccess: enrolledNamespaceAccess);
  }

  /// Verifies if the provided `namespace` has super set access based on the
  /// namespaces defined in `enrollDataStoreValue`.
  ///
  /// This function checks if the given `namespace` is a subset or exact match
  /// of any namespace in the `enrollDataStoreValue`. If so, it returns the
  /// matched namespace and its access level. If `enrollDataStoreValue`
  /// contains a wildcard (`*`), it grants access to all namespaces.
  ///
  /// Example:
  /// - Given approving app does not have access to '*' namespace.
  ///   - If enrolling `namespace` is "orders.myapp" and approving app namespace is "orders.myapp", then ("orders.myapp", "rw") is returned.
  ///   - If enrolling `namespace` is "data.orders.myapp" and approving app namespace is "orders.myapp", then ("orders.myapp", "rw")  is returned.
  ///   - If enrolling `namespace` is "data.myapp" and approving app namespace is "orders.myapp", then and empty string, null are returned,
  ///     representing no matching authorised namespace found (Since enrollment does not have access to '*' namespace).
  ///
  /// - Given approving app does not have access to '*' namespace.
  ///   - If enrolling `namespace` is "data.myapp" and approving app namespace is "orders.myapp", then ("*", "rw") is returned.
  ///
  /// - Parameters:
  ///   - enrollDataStoreValue: The `EnrollDataStoreValue` containing namespaces and their access levels.
  ///   - namespace: The namespace to be verified.
  ///
  /// - Returns: A tuple containing the authorised namespace and its access level.
  ///   If no matching namespace is found, it returns an empty string and `null` for access.
  (String, String?) _checkForNamespaceAuthorization(
      EnrollDataStoreValue enrollDataStoreValue,
      String? namespace,
      String? keyWithNamespace) {
    String authorisedNamespace = '';
    String? access;
    for (String enrolledNamespace in enrollDataStoreValue.namespaces.keys) {
      if ('.$namespace'.endsWith('.$enrolledNamespace')) {
        authorisedNamespace = enrolledNamespace;
        break;
      }
    }

    /// If the namespace contains a period ('.'), AtKey(key).namespace will return only the last segment of the namespace.
    /// For example, if the namespace is 'foo.bar', AtKey(key).namespace will return 'bar'. In such cases, authorisedNamespace
    /// cannot be cannot be fetched due to incomplete namespace.
    /// Currently, to authorize such keys, use the full key along with the namespace to perform the authorization check.
    if (keyWithNamespace != null && authorisedNamespace.isEmpty) {
      for (String enrolledNamespace in enrollDataStoreValue.namespaces.keys) {
        if (keyWithNamespace.endsWith('.$enrolledNamespace')) {
          authorisedNamespace = enrolledNamespace;
          break;
        }
      }
    }
    // If enrolledDataStore value contains *, it means at is authorised for all namespaces
    if (authorisedNamespace.isEmpty &&
        enrollDataStoreValue.namespaces.containsKey(allNamespaces)) {
      authorisedNamespace = allNamespaces;
    }
    access = enrollDataStoreValue.namespaces[authorisedNamespace];
    return (authorisedNamespace, access);
  }

  bool _applyEnrollmentValidations(EnrollDataStoreValue enrollDataStoreValue,
      String operation, String? atKey, String? namespace) {
    // Only approved enrollmentId is authorised to perform operations. Return false for enrollments
    // which are not approved.
    if (enrollDataStoreValue.approval?.state !=
        EnrollmentStatus.approved.name) {
      return false;
    }
    // Only the enrollmentId with access to "__manage" namespace can approve, deny, revoke
    // an enrollment request. If enrollmentId does not have access to "__manage" access, then
    // cannot perform enrollment operations.
    if (operation.isNotEmpty &&
        enrollDataStoreValue.namespaces.containsKey(enrollManageNamespace) ==
            false) {
      logger.warning(
          'Failed to $operation  the request. The enrollment does not have access to "__manage" namespace');
      throw AtEnrollmentException(
          'The approving enrollment does not have access to "__manage" namespace');
    }

    if (atKey != null && namespace != null) {
      AtKey atKeyObj;
      try {
        atKeyObj = AtKey.fromString(atKey);
      } catch (e) {
        throw AtEnrollmentException('AtKey.fromString($atKey) failed: $e');
      }
      if (atKeyObj.namespace != namespace) {
        throw AtEnrollmentException(
            'AtKey namespace and passed namespace do not match');
      }
    }
    return true;
  }

  bool checkEnrollmentNamespaceAccess(String authorisedNamespaceAccess,
      {String enrolledNamespaceAccess = ''}) {
    return _isReadAllowed(getVerb(), authorisedNamespaceAccess) ||
        _isWriteAllowed(getVerb(), authorisedNamespaceAccess);
  }

  bool _isReadAllowed(Verb verb, String access) {
    return (verb is LocalLookup ||
            verb is Lookup ||
            verb is NotifyFetch ||
            verb is NotifyStatus ||
            verb is NotifyList ||
            verb is Monitor) &&
        (access == 'r' || access == 'rw');
  }

  bool _isWriteAllowed(Verb verb, String access) {
    return (verb is Update ||
            verb is Delete ||
            verb is Notify ||
            verb is NotifyAll ||
            verb is NotifyRemove ||
            verb is Monitor) &&
        access == 'rw';
  }

  bool _isReservedKey(String? atKey) {
    return atKey == null
        ? false
        : AtKey.getKeyType(atKey) == KeyType.reservedKey;
  }

  /// This function checks the validity of a provided OTP.
  /// It returns true if the OTP is valid; otherwise, it returns false.
  /// If the OTP is not found in the keystore, it also returns false.
  ///
  /// Additionally, this function removes the OTP from the keystore to prevent
  /// its reuse.
  Future<bool> isPasscodeValid(String? passcode) async {
    if (passcode == null) {
      return false;
    }
    // 1. Check if user has configured an SPP(Semi-Permanent Pass-code).
    // If SPP key is available, check if the otp sent is a valid pass code.
    // If yes, return true, else check it is a valid OTP.
    String passcodeKey = OtpVerbHandler.passcodeKey(passcode, isSpp: true);
    if (!keyStore.isKeyExists(passcodeKey)) {
      // if new SPPKey does not exist in keystore, check for SPP data against legacy SPP key
      // New SPP key has __otp namespace, legacy key does NOT have any namespace
      passcodeKey =
          'private:spp${AtSecondaryServerImpl.getInstance().currentAtSign}';
    }
    try {
      AtData? sppAtData = await keyStore.get(passcodeKey);
      // SPP has a special key so we have to check the value that was stored
      // (which is the actual SPP)
      // By comparison, OTPs are stored with the key being ${OTP}.__otp@alice
      // i.e. the OTP is part of the key, and the stored data is irrelevant
      if (sppAtData?.data?.toLowerCase() == passcode.toLowerCase()) {
        if (SecondaryUtil.isActiveKey(sppAtData)) {
          return true;
        } else {
          logger.finest(
              'SPP found in KeyStore but has expired. Validating as OTP');
        }
      }
    } on KeyNotFoundException {
      logger.finest('No SPP found in KeyStore. Validating as OTP');
    }

    // 2. If not a valid SPP, then check against OTP keys
    String otpKey = OtpVerbHandler.passcodeKey(passcode, isSpp: false);
    if (!keyStore.isKeyExists(otpKey)) {
      // if new OTPKey does not exist in keystore, check for OTP data against legacy OTPKey
      // New OTP key has __otp namespace, legacy key does not have namespace
      otpKey =
          'private:${passcode.toLowerCase()}${AtSecondaryServerImpl.getInstance().currentAtSign}';
    }

    AtData? otpAtData;
    try {
      otpAtData ??= await keyStore.get(otpKey);
    } on KeyNotFoundException {
      logger.finer('OTP NOT found in KeyStore');
      return false;
    }

    bool isOTPValid = SecondaryUtil.isActiveKey(otpAtData);
    // Remove the OTP after it is used.
    // NOTE: SPP code should NOT be deleted. only OTPs should be
    // deleted after use.
    await keyStore.remove(otpKey);

    return isOTPValid;
  }
}
