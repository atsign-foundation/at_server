import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart' as handler_util;
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';

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
    var handler = responseManager.getResponseHandler(getVerb());
    await handler.process(atConnection, response);
  }

  Future<Response> processInternal(
      String command, InboundConnection atConnection) async {
    var response = Response();
    var atConnectionMetadata = atConnection.metaData;
    if (getVerb().requiresAuth() && !atConnectionMetadata.isAuthenticated) {
      throw UnAuthenticatedException('Command cannot be executed without auth');
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
      if (!SecondaryUtil.isActiveKey(enrollData) &&
          enrollDataStoreValue.approval!.state !=
              EnrollmentStatus.approved.name) {
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
  Future<bool> isAuthorized(
      InboundConnectionMetadata connectionMetadata, String? atKey,
      {String? namespace}) async {
    final Verb verb = getVerb();

    final enrollmentId = connectionMetadata.enrollmentId;

    if (enrollmentId == null || _isReservedKey(atKey)) {
      return true;
    }

    final enrollmentKey =
        '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace';
    final fullKey =
        '$enrollmentKey${AtSecondaryServerImpl.getInstance().currentAtSign}';

    final EnrollDataStoreValue enrollDataStoreValue;
    try {
      enrollDataStoreValue = await getEnrollDataStoreValue(fullKey);
    } on KeyNotFoundException {
      logger.shout('Could not retrieve enrollment data for $fullKey');
      return false;
    }

    if (enrollDataStoreValue.approval?.state !=
        EnrollmentStatus.approved.name) {
      logger.warning('Enrollment state for $fullKey'
          ' is ${enrollDataStoreValue.approval?.state}');
      return false;
    }

    final enrollNamespaces = enrollDataStoreValue.namespaces;
    // set passed namespace. If passed namespace is null, get namespace from atKey
    final keyNamespace =
        namespace ?? (atKey != null ? AtKey.fromString(atKey).namespace : null);
    if (keyNamespace == null && atKey == null) {
      logger.shout('Both key and namespace are null');
      return false;
    }

    logger.finer('enrollNamespaces:$enrollNamespaces');
    logger.finer('keyNamespace:$keyNamespace');
    final access = enrollNamespaces.containsKey(allNamespaces)
        ? enrollNamespaces[allNamespaces]
        : enrollNamespaces[keyNamespace];
    logger.finer('access:$access');

    logger.shout('Verb: $verb, keyNamespace: $keyNamespace, access: $access');

    if (access == null) {
      return false;
    }

    // Only spp and enroll operations are allowed to access
    // the enrollManageNamespace
    if (keyNamespace == enrollManageNamespace) {
      return (verb is Otp || verb is Enroll)
          ? (access == 'r' || access == 'rw')
          : false;
    }

    // if there is no namespace, connection should have * in namespace for access
    if (keyNamespace == null && enrollNamespaces.containsKey(allNamespaces)) {
      if (_isReadAllowed(verb, access) || _isWriteAllowed(verb, access)) {
        return true;
      }
      return false;
    }
    return _isReadAllowed(verb, access) || _isWriteAllowed(verb, access);
  }

  bool _isReadAllowed(Verb verb, String access) {
    return (verb is LocalLookup ||
            verb is Lookup ||
            verb is NotifyFetch ||
            verb is NotifyStatus ||
            verb is NotifyList) &&
        (access == 'r' || access == 'rw');
  }

  bool _isWriteAllowed(Verb verb, String access) {
    return (verb is Update ||
            verb is Delete ||
            verb is Notify ||
            verb is NotifyAll ||
            verb is NotifyRemove) &&
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
  Future<bool> isOTPValid(String? otp) async {
    if (otp == null) {
      return false;
    }
    // Check if user have configured SPP(Semi-Permanent Pass-code).
    // If SPP key is available, check if the otp sent is a valid pass code.
    // If yes, return true, else check it is a valid OTP.
    String sppKey =
        'private:spp${AtSecondaryServerImpl.getInstance().currentAtSign}';
    if (keyStore.isKeyExists(sppKey)) {
      AtData atData = await keyStore.get(sppKey);
      if (atData.data?.toLowerCase() == otp.toLowerCase()) {
        return true;
      }
    }
    // If SPP is not valid, then check if the provided otp is valid.
    String otpKey =
        'private:${otp.toLowerCase()}${AtSecondaryServerImpl.getInstance().currentAtSign}';
    AtData otpAtData;
    try {
      otpAtData = await keyStore.get(otpKey);
    } on KeyNotFoundException {
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
