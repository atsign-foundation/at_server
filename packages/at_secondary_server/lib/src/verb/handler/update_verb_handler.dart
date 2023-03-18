import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

// UpdateVerbHandler is used to process update verb
// update can be used to update the public/private keys
// Ex: update:public:email@alice alice@atsign.com \n
class UpdateVerbHandler extends AbstractUpdateVerbHandler {
  static Update update = Update();

  UpdateVerbHandler(
      SecondaryKeyStore keyStore, NotificationManager notificationManager)
      : super(keyStore, notificationManager);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith('update:') && !command.startsWith('update:meta');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return update;
  }

  // Method which will process update Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var updatePreProcessResult =
        await super.preProcessAndNotify(response, verbParams, atConnection);

    var updateParams = updatePreProcessResult.updateParams;

    logger.finer(
        'calling keyStore.put(${updatePreProcessResult.atKey}, ${updatePreProcessResult.atData}');

    // update the key in data store
    var result = await keyStore.put(
        updatePreProcessResult.atKey, updatePreProcessResult.atData,
        time_to_live: updateParams.metadata!.ttl,
        time_to_born: updateParams.metadata!.ttb,
        time_to_refresh: updateParams.metadata!.ttr,
        isCascade: updateParams.metadata!.ccd,
        isBinary: updateParams.metadata!.isBinary,
        isEncrypted: updateParams.metadata!.isEncrypted,
        dataSignature: updateParams.metadata!.dataSignature,
        sharedKeyEncrypted: updateParams.metadata!.sharedKeyEnc,
        publicKeyChecksum: updateParams.metadata!.pubKeyCS,
        encoding: updateParams.metadata!.encoding,
        encKeyName: updateParams.metadata!.encKeyName,
        encAlgo: updateParams.metadata!.encAlgo,
        ivNonce: updateParams.metadata!.ivNonce,
        skeEncKeyName: updateParams.metadata!.skeEncKeyName,
        skeEncAlgo: updateParams.metadata!.skeEncAlgo);
    response.data = result?.toString();
  }
}
