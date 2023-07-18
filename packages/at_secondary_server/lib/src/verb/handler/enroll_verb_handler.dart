import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/verb/handler/totp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
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

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final responseJson = {};
    logger.finer('verb params: $verbParams');
    final operation = verbParams['operation'];
    final currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;

    try {
      switch (operation) {
        case 'request':
          if (!atConnection.getMetaData().isAuthenticated) {
            var totp = verbParams['totp'];
            if (totp == null ||
                (await TotpVerbHandler.cache.get(totp)) == null) {
              throw AtEnrollmentException(
                  'invalid totp. Cannot process enroll request');
            }
          }
          List<EnrollNamespace> enrollNamespaces =
              (verbParams['namespaces'] ?? '')
                  .split(';')
                  .map((namespace) => EnrollNamespace(
                      namespace.split(',')[0], namespace.split(',')[1]))
                  .toList();
          logger.finer('enrollNamespaces: $enrollNamespaces');

          var enrollmentId = Uuid().v4();
          var key =
              '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace';
          logger.finer('key: $key$currentAtSign');

          responseJson['enrollmentId'] = enrollmentId;
          final enrollmentValue = EnrollDataStoreValue(
              atConnection.getMetaData().sessionID!,
              verbParams['appName']!,
              verbParams['deviceName']!,
              verbParams['apkamPublicKey']!);

          if (atConnection.getMetaData().isAuthenticated) {
            // approve request from connection that are authenticated. This connection may be cram or legacyPkam authenticated
            enrollNamespaces.add(EnrollNamespace(enrollManageNamespace, 'rw'));
            enrollmentValue.approval =
                EnrollApproval(EnrollStatus.approved.name);
            final inboundConnectionMetadata =
                atConnection.getMetaData() as InboundConnectionMetadata;
            inboundConnectionMetadata.enrollApprovalId = enrollmentId;
            responseJson['status'] = 'success';
          } else {
            enrollmentValue.approval =
                EnrollApproval(EnrollStatus.pending.name);
            await _storeNotification(key, currentAtSign);
            responseJson['status'] = 'pending';
          }

          enrollmentValue.namespaces = enrollNamespaces;
          enrollmentValue.requestType = EnrollRequestType.newEnrollment;
          AtData enrollData = AtData()
            ..data = jsonEncode(enrollmentValue.toJson());
          logger.finer('enrollData: $enrollData');

          await keyStore.put('$key$currentAtSign', enrollData);
          break;

        case 'approve':
        case 'deny':
          final enrollmentId = verbParams['enrollmentId'];
          var key =
              '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace';
          logger.finer('key: $key$currentAtSign');
          var enrollData;
          try {
            enrollData = await keyStore.get('$key$currentAtSign');
          } on KeyNotFoundException {
            throw AtEnrollmentException(
                'enrollment id: $enrollmentId not found in keystore');
          }
          if (enrollData != null) {
            final existingAtData = enrollData.data;
            var enrollDataStoreValue =
                EnrollDataStoreValue.fromJson(jsonDecode(existingAtData));

            if (operation == 'approve') {
              enrollDataStoreValue.approval!.state = EnrollStatus.approved.name;
              responseJson['status'] = 'approved';
            } else if (operation == 'deny') {
              enrollDataStoreValue.approval!.state = EnrollStatus.denied.name;
              responseJson['status'] = 'denied';
            }

            AtData updatedEnrollData = AtData()
              ..data = jsonEncode(enrollDataStoreValue.toJson());

            await keyStore.put('$key$currentAtSign', updatedEnrollData);
          }

          responseJson['enrollmentId'] = enrollmentId;
          break;
      }
    } catch (e, stackTrace) {
      responseJson['status'] = 'exception';
      responseJson['reason'] = e.toString();
      logger.severe('Exception: $e\n$stackTrace');
    }

    response.data = jsonEncode(responseJson);
  }

  Future<void> _storeNotification(String notificationKey, String atSign) async {
    try {
      final atNotification = (AtNotificationBuilder()
            ..notification = notificationKey
            ..fromAtSign = atSign
            ..toAtSign = atSign
            ..ttl = 24 * 60 * 60 * 1000
            ..type = NotificationType.self
            ..opType = OperationType.update)
          .build();
      final notificationId =
          await NotificationUtil.storeNotification(atNotification);
      logger.finer('notification generated: $notificationId');
    } on Exception catch (e, trace) {
      logger.severe(
          'Exception while storing notification key $notificationKey. Exception $e. Trace $trace');
    } on Error catch (e, trace) {
      logger.severe(
          'Error while storing notification key $notificationKey. Error $e. Trace $trace');
    }
  }
}
