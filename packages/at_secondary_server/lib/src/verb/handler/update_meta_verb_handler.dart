import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/metadata/at_metadata_builder.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';

class UpdateMetaVerbHandler extends AbstractUpdateVerbHandler {
  static UpdateMeta updateMeta = UpdateMeta();

  UpdateMetaVerbHandler(SecondaryKeyStore keyStore,
      StatsNotificationService statsNotificationService, notificationManager)
      : super(keyStore, statsNotificationService, notificationManager);

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
    final atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AtData? existingData;

    try {
      existingData = await keyStore.get(updatePreProcessResult.atKey);
    } on KeyNotFoundException {
      // do nothing
    }
    var newMetadata = AtMetadataBuilder(
        newMetaData: updatePreProcessResult.atData.metaData!,
        existingMetaData: existingData?.metaData,
        atSign: atSign)
        .build();
    // update the key in data store
    logger.finer(
        'calling keyStore.putMeta(${updatePreProcessResult.atKey}, $newMetadata');
    var result =
    await keyStore.putMeta(updatePreProcessResult.atKey, newMetadata);
    response.data = result?.toString();
  }
}