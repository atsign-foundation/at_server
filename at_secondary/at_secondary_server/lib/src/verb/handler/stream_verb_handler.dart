import 'dart:collection';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/connection/stream_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/response.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class StreamVerbHandler extends AbstractVerbHandler {
  static StreamVerb stream = StreamVerb();

  InboundConnection atConnection;

  StreamVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.stream));

  @override
  Verb getVerb() {
    return stream;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    if (!atConnection.getMetaData().isAuthenticated &&
        !atConnection.getMetaData().isPolAuthenticated) {
      throw UnAuthenticatedException('Stream verb requires either pol or auth');
    }
    logger.info('inside stream verb handler');
    var operation = verbParams['operation'];
    var receiver = verbParams['receiver'];
    var streamId = verbParams['streamId'];
    var fileName = verbParams['fileName'];
    var fileLength = verbParams['length'];
    streamId = streamId.trim();
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    switch (operation) {
      case 'receive':
        StreamManager.receiverSocketMap[streamId] = atConnection;
        var senderConnection = StreamManager.senderSocketMap[streamId];
        senderConnection.getMetaData().isStream = true;
        senderConnection.getMetaData().streamId = streamId;
        atConnection.getMetaData().streamId = streamId;
        senderConnection.receiverSocket =
            StreamManager.receiverSocketMap[streamId].getSocket();
        logger.info('writing stream ack');
        senderConnection.getSocket().write('stream:ack ${streamId}\n');
        break;
      case 'done':
        StreamManager.senderSocketMap[streamId]
            .write('stream:done ${streamId}\n');
        await StreamManager.receiverSocketMap[streamId].getSocket().destroy();
        await StreamManager.senderSocketMap[streamId].getSocket().destroy();
        break;
      case 'init':
        logger.info('forAtSign:${receiver}');
        logger.info('streamid:${streamId}');
        fileName = fileName.trim();
        logger.info('fileName:${fileName}');
        logger.info('fileLength:${fileLength}');
        await NotificationUtil.storeNotification(
            atConnection,
            AtSecondaryServerImpl.getInstance().currentAtSign,
            receiver,
            'stream_id',
            NotificationType.sent,
            null);
        var notificationKey =
            '@${receiver}:stream_id ${currentAtSign}:${streamId}:${fileName}:${fileLength}';

        await NotificationUtil.sendNotification(
            receiver, atConnection, notificationKey);
        StreamManager.senderSocketMap[streamId] = atConnection;
        break;
    }
    response.isStream = true;
  }
}
