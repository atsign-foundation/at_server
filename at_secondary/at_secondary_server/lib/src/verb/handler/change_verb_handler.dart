import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Responsible for sending the latest commitId to the StatsNotificationService.
abstract class ChangeVerbHandler extends AbstractVerbHandler {
  ChangeVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  Response? _responseInternal;

  /// Delegates call to the
  @override
  Future<void> process(String command, InboundConnection atConnection) async {
    await super.process(command, atConnection);
    if (_responseInternal != null &&
        _responseInternal!.isError == false &&
        _responseInternal!.data != null) {
      await StatsNotificationService.getInstance()
          .writeStatsToMonitor(latestCommitID: _responseInternal!.data);
    }
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    _responseInternal = response;
  }
}
