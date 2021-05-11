import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/connection/stream_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/verb.dart';

class StreamVerbHandler extends AbstractVerbHandler {
  static StreamVerb stream = StreamVerb();

  InboundConnection? atConnection;

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
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    logger.info('inside stream verb handler');
    var operation = verbParams['operation'];
    var receiver = verbParams['receiver'];
    var streamId = verbParams['streamId']!;
    var fileName = verbParams['fileName'];
    var fileLength = verbParams['length'];
    var namespace = verbParams['namespace'];
    streamId = streamId.trim();
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    switch (operation) {
      case 'receive':
        StreamManager.receiverSocketMap[streamId] = atConnection;
        var senderConnection = StreamManager.senderSocketMap[streamId];
        if (senderConnection == null) {
          logger.severe('sender connection is null for stream id:$streamId');
          throw UnAuthenticatedException('Invalid stream id');
        }
        senderConnection.getMetaData().isStream = true;
        senderConnection.getMetaData().streamId = streamId;
        atConnection.getMetaData().streamId = streamId;
        senderConnection.receiverSocket =
            StreamManager.receiverSocketMap[streamId]!.getSocket();
        logger.info('writing stream ack');
        senderConnection.getSocket().write('stream:ack ${streamId}\n');
        break;
      case 'done':
        var senderConnection = StreamManager.senderSocketMap[streamId];
        if (senderConnection == null) {
          logger.severe('sender connection is null for stream id:$streamId');
          throw UnAuthenticatedException('Invalid stream id');
        }
        StreamManager.senderSocketMap[streamId]!
            .write('stream:done ${streamId}\n');
        StreamManager.receiverSocketMap[streamId]!.getSocket().destroy();
        StreamManager.senderSocketMap[streamId]!.getSocket().destroy();
        StreamManager.receiverSocketMap.remove(streamId);
        StreamManager.senderSocketMap.remove(streamId);
        break;
      case 'init':
        if (!atConnection.getMetaData().isAuthenticated &&
            !atConnection.getMetaData().isPolAuthenticated) {
          throw UnAuthenticatedException(
              'Stream init requires either pol or auth');
        }
        logger.info('forAtSign:${receiver}');
        logger.info('streamid:${streamId}');
        fileName = fileName!.trim();
        logger.info('fileName:${fileName}');
        logger.info('fileLength:${fileLength}');
        var streamKey = 'stream_id';
        if (namespace != null && namespace.isNotEmpty && namespace != 'null') {
          streamKey = '$streamKey.$namespace';
        }

        var notificationKey =
            '@${receiver}:$streamKey ${currentAtSign}:${streamId}:${fileName}:${fileLength}';

        _notify(receiver, AtSecondaryServerImpl.getInstance().currentAtSign,
            notificationKey);
        StreamManager.senderSocketMap[streamId] = atConnection;
        break;
    }
    response.isStream = true;
  }

  void _notify(forAtSign, atSign, key) {
    if (forAtSign == null) {
      return;
    }
    var atNotification = (AtNotificationBuilder()
          ..type = NotificationType.sent
          ..fromAtSign = atSign
          ..toAtSign = forAtSign
          ..notification = key
          ..opType = OperationType.update)
        .build();
    NotificationManager.getInstance().notify(atNotification);
  }
}
