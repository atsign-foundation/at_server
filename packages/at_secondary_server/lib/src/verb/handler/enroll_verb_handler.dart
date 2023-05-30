import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/enroll/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
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
      List<String> namespaces = verbParams['namespaces']!.split(';');
      List<EnrollNamespace> enrollNamespaces = [];
      for (String namespace in namespaces) {
        String name = namespace.split(',')[0];
        String access = namespace.split(',')[1];
        enrollNamespaces.add(EnrollNamespace(name, access));
      }
      logger.finer('enrollNamespaces: $enrollNamespaces');

      final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      var approvalId = Uuid().v4();
      var key = '$approvalId.$newEnrollmentKeyPattern.$enrollManageNamespace';
      logger.finer('key: $key$currentAtSign');

      responseJson['approvalId'] = approvalId;
      final enrollmentValue = EnrollDataStoreValue(
          atConnection.getMetaData().sessionID!,
          verbParams['appName']!,
          verbParams['deviceName']!,
          verbParams['apkamPublicKey']!);
      if (atConnection.getMetaData().authType == AuthType.cram) {
        // first client/app enrollment request for the atsign. enroll automatically.
        // add rw access for __manage for the first app since it is already cram authenticated
        enrollNamespaces.add(EnrollNamespace(enrollManageNamespace, 'rw'));
        enrollmentValue.approval = EnrollApproval(EnrollStatus.approved.name);
        responseJson['status'] = 'success';
      } else {
        enrollmentValue.approval = EnrollApproval(EnrollStatus.pending.name);

        // var notificationId =
        //     await NotificationManager.getInstance().notify(atNotification);
        // logger.finer('notificationId:$notificationId');
        await _sendNotificationToManageNamespaces(currentAtSign);
        responseJson['status'] = 'pending';
      }
      enrollmentValue.namespaces = enrollNamespaces;
      AtData enrollData = AtData()..data = jsonEncode(enrollmentValue.toJson());
      logger.finer('enrollData: $enrollData');
      await keyStore.put('$key$currentAtSign', enrollData);

      response.data = jsonEncode(responseJson);
    } on Exception catch (e) {
      responseJson['status'] = 'exception';
      responseJson['reason'] = e.toString();
    } on Error catch (e) {
      responseJson['status'] = 'error';
      responseJson['reason'] = e.toString();
    }
  }

  Future<void> _sendNotificationToManageNamespaces(String atSign) async {
    InboundConnectionPool inboundConnectionPool =
        InboundConnectionPool.getInstance();
    var connectionsList = inboundConnectionPool.getConnections();
    for (var connection in connectionsList) {
      var connectionMetadata =
          connection.getMetaData() as InboundConnectionMetadata;
      logger.finer(
          'enrollId: ${connectionMetadata.enrollApprovalId} isMonitor: ${connection.isMonitor}');
      if (connection.isMonitor != null && connection.isMonitor!) {
        if (connectionMetadata.enrollApprovalId != null) {
          var key =
              '${connectionMetadata.enrollApprovalId}.$newEnrollmentKeyPattern.$enrollManageNamespace$atSign';
          var enrollData = await keyStore.get(key);
          if (enrollData != null) {
            final atData = enrollData.data;
            final enrollDataStoreValue =
                EnrollDataStoreValue.fromJson(jsonDecode(atData));
            logger.finer('namespaces: ${enrollDataStoreValue.namespaces}');
            for (EnrollNamespace namespace in enrollDataStoreValue.namespaces) {
              if (namespace.name == enrollManageNamespace) {
                try {
                  Notification notification = Notification.empty();
                  notification
                    ..id = Uuid().v4()
                    ..dateTime = DateTime.now().toUtc().millisecondsSinceEpoch
                    ..fromAtSign = atSign
                    ..toAtSign = atSign
                    ..messageType = MessageType.key.toString()
                    ..notification = key;
                  logger.finer(notification.toJson());
                  logger.finer(
                      'sending notification for enroll request. notification key - $key');
                  connection.write(
                      'notification: ${jsonEncode(notification.toJson())}\n');
                } on Exception catch (e, trace) {
                  print(e);
                  print(trace);
                } on Error catch (e, trace) {
                  print(e);
                  print(trace);
                }
                break;
              } else {
                logger.finer('namespace not equal');
              }
            }
          }
        }
      }
    }
  }
}
