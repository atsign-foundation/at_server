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
      return enrollDataStoreValue;
    } on KeyNotFoundException {
      logger.severe('$enrollmentKey does not exist in the keystore');
      rethrow;
    }
  }

  /// Check whether the given client enrollment with [enrollmentId] is authorized to access [keyNamespace]
  /// Global(__global) and manage(__manage) namespaces are accessible only by keys verb. Access to these namespaces to other verbs is not allowed.
  /// This method retrieves the list of enrollment data namespaces from keystore for the enrollment [enrollmentId] and compares with the passed [namespace]
  /// Returns true if passed [keyNamespace] is in the list of namespaces from keystore and has required access to [keyNamespace]
  /// Returns false if passed [keyNamespace] is not in the list of namespaces from keystore or doesn't have required access to [keyNamespace]
  /// Returns false if approval state of [enrollmentId] is not [EnrollStatus.approved]
  Future<bool> isAuthorized(String enrollmentId, String keyNamespace) async {
    EnrollDataStoreValue enrollDataStoreValue;
    // global/manage namespace can be accessed only by keys: verb.
    // Restrict other verbs access
    if (keyNamespace == globalNamespace ||
        keyNamespace == enrollManageNamespace) {
      return false;
    }
    final enrollmentKey =
        '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace';
    try {
      enrollDataStoreValue = await getEnrollDataStoreValue(
          '$enrollmentKey${AtSecondaryServerImpl.getInstance().currentAtSign}');
    } on KeyNotFoundException {
      // When a key with enrollmentId is not found, atSign is not authorized to
      // perform enrollment actions. Return false.
      return false;
    }

    if (enrollDataStoreValue.approval?.state != EnrollStatus.approved.name) {
      return false;
    }

    final enrollNamespaces = enrollDataStoreValue.namespaces;

    logger.finer(
        'keyNamespace: $keyNamespace enrollNamespaces: $enrollNamespaces');
    // keys in __manage namespace should not be accessible
    if (keyNamespace != enrollManageNamespace &&
        enrollNamespaces.containsKey(keyNamespace)) {
      var access = enrollNamespaces[keyNamespace];
      logger.finer('current verb: ${getVerb()}');
      if (getVerb() is LocalLookup || getVerb() is Lookup) {
        if (access == 'r' || access == 'rw') {
          return true;
        }
      } else if (getVerb() is Update || getVerb() is Delete) {
        if (access == 'rw') {
          return true;
        }
      }
    }
    return false;
  }
}
