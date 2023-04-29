import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Responsible for sending the latest commitId to the StatsNotificationService.
/// The verbHandlers responsible for generating change in keystore should extend this
/// verbHandler to write the commitId to SDK.
abstract class ChangeVerbHandler extends AbstractVerbHandler {
  final StatsNotificationService statsNotificationService;
  ChangeVerbHandler(SecondaryKeyStore keyStore, this.statsNotificationService)
      : super(keyStore);

  Response? _responseInternal;

  /// Delegates call to the [AbstractVerbHandler] to process the verb and call [StatsNotificationService]
  @override
  Future<void> process(String command, InboundConnection atConnection) async {
    await super.process(command, atConnection);
    if (_responseInternal != null &&
        _responseInternal!.isError == false &&
        _responseInternal!.data != null) {
      statsNotificationService.writeStatsToMonitor(
          latestCommitID: _responseInternal!.data,
          operationType: getVerb().name());
    }
  }

  /// Sets [Response] to [_responseInternal]
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    _responseInternal = response;
  }
}
