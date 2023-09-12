import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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
    var atConnectionMetadata = atConnection.getMetaData();
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
          enrollDataStoreValue.approval!.state != EnrollStatus.approved.name) {
        enrollDataStoreValue.approval?.state = EnrollStatus.expired.name;
      }
      return enrollDataStoreValue;
    } on KeyNotFoundException {
      logger.severe('$enrollmentKey does not exist in the keystore');
      rethrow;
    }
  }

  /// Verifies whether the enrollment namespace for the enrollment
  /// ID has the necessary permissions to modify, delete, or retrieve the data.
  /// The enrollment should be in an approved state.
  ///
  /// To execute a data retrieval (lookup or local lookup), the namespace must have
  /// "r" (read) privileges within the namespace.
  /// For update or delete actions, the namespace must have "rw" (read-write) privileges.
  ///
  /// Returns true, if the namespace has the required read or read-write
  /// permissions to execute lookup/local-lookup or update/delete operations
  /// respectively
  ///
  /// Returns false
  ///  - If the enrollment key is not present in the keystore.
  ///  - If the enrollment is not in "approved" state
  ///  - If the namespace does not have necessary permissions to perform the operation
  ///  - If enrollment is a part of "global" or "manage" namespace
  Future<bool> isAuthorized(String enrollmentId, String keyNamespace) async {
    try {
      final enrollmentKey =
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace';
      final fullKey =
          '$enrollmentKey${AtSecondaryServerImpl.getInstance().currentAtSign}';

      final enrollDataStoreValue = await getEnrollDataStoreValue(fullKey);

      if (enrollDataStoreValue.approval?.state != EnrollStatus.approved.name) {
        return false;
      }

      final enrollNamespaces = enrollDataStoreValue.namespaces;
      logger.finer('enrollNamespaces:$enrollNamespaces');
      logger.finer('keyNamespace:$keyNamespace');
      final access = enrollNamespaces.containsKey(allNamespaces)
          ? enrollNamespaces[allNamespaces]
          : enrollNamespaces[keyNamespace];
      logger.finer('access:$access');
      if (keyNamespace != enrollManageNamespace && access != null) {
        final verb = getVerb();
        if ((verb is LocalLookup || verb is Lookup) &&
            (access == 'r' || access == 'rw')) {
          return true;
        } else if ((verb is Update || verb is Delete) && access == 'rw') {
          return true;
        }
      }
      return false;
    } on KeyNotFoundException {
      return false;
    }
  }
}
