import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/enroll/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:uuid/uuid.dart';
import 'abstract_verb_handler.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class EnrollVerbHandler extends AbstractVerbHandler {
  static Enroll enrollVerb = Enroll();

  EnrollVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) => command.startsWith('enroll:');

  @override
  Verb getVerb() => enrollVerb;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final responseJson = {};
    logger.finer('verb params: $verbParams');
    try {
      if (atConnection.getMetaData().authType == AuthType.cram) {
        // first client/app enrollment request for the atsign. enroll automatically.
        var approvalId = Uuid().v4();
        responseJson['approvalId'] = approvalId;
        var key = '$approvalId.$newEnrollmentKeyPattern.$enrollManageNamespace';
        final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
        List<String> namespaces = verbParams['namespaces']!.split(';');
        List<EnrollNamespace> enrollNamespaces = [];
        // add rw access for __manage for the first app since it is already cram authenticated
        enrollNamespaces.add(EnrollNamespace(enrollManageNamespace, 'rw'));
        for (String namespace in namespaces) {
          String name = namespace.split(',')[0];
          String access = namespace.split(',')[1];
          enrollNamespaces.add(EnrollNamespace(name, access));
        }
        logger.finer('enrollNamespaces: $enrollNamespaces');
        final enrollmentValue = EnrollDataStoreValue(
            atConnection.getMetaData().sessionID!,
            verbParams['appName']!,
            verbParams['deviceName']!,
            verbParams['apkamPublicKey']!)
          ..namespaces = enrollNamespaces;
        AtData enrollData = AtData()
          ..data = jsonEncode(enrollmentValue.toJson());
        logger.finer('key: $key$currentAtSign');
        logger.finer('enrollData: $enrollData');
        await keyStore.put('$key$currentAtSign', enrollData);
        responseJson['status'] = 'success';
      }
    } on Exception catch (e) {
      responseJson['status'] = 'exception';
      responseJson['reason'] = e.toString();
    } on Error catch (e) {
      responseJson['status'] = 'error';
      responseJson['reason'] = e.toString();
    }
    response.data = jsonEncode(responseJson);
  }
}
