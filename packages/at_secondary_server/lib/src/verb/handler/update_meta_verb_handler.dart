import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';

class UpdateMetaVerbHandler extends AbstractUpdateVerbHandler {
  static UpdateMeta updateMeta = UpdateMeta();

  UpdateMetaVerbHandler(
      SecondaryKeyStore keyStore, NotificationManager notificationManager)
      : super(keyStore, notificationManager);

  @override
  bool accept(String command) => command.startsWith('update:meta:');

  @override
  Verb getVerb() => updateMeta;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var updatePreProcessResult =
        await super.preProcessAndNotify(response, verbParams, atConnection);

    // update the key in data store
    logger.finer(
        'calling keyStore.putMeta(${updatePreProcessResult.atKey}, ${updatePreProcessResult.atData.metaData!}');
    var result = await keyStore.putMeta(
        updatePreProcessResult.atKey, updatePreProcessResult.atData.metaData!);
    response.data = result?.toString();
  }
}
