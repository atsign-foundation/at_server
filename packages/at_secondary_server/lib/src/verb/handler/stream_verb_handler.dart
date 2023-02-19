import 'dart:collection';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/stream_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/at_server_spec.dart';

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
    var startByte = verbParams['startByte'];
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
        senderConnection.getSocket().write('stream:ack $streamId\n');
        break;
      case 'done':
        var senderConnection = StreamManager.senderSocketMap[streamId];
        if (senderConnection == null) {
          logger.severe('sender connection is null for stream id:$streamId');
          throw UnAuthenticatedException('Invalid stream id');
        }
        StreamManager.senderSocketMap[streamId]!
            .write('stream:done $streamId\n');
        _cleanUp(streamId);
        break;
      case 'init':
        if (!atConnection.getMetaData().isAuthenticated &&
            !atConnection.getMetaData().isPolAuthenticated) {
          throw UnAuthenticatedException(
              'Stream init requires either pol or auth');
        }
        logger.info('forAtSign:$receiver');
        logger.info('streamId:$streamId');
        fileName = fileName!.trim();
        logger.info('fileName:$fileName');
        logger.info('fileLength:$fileLength');
        logger.info('startByte:$startByte');
        var streamKey = 'stream_id';
        if (namespace != null && namespace.isNotEmpty && namespace != 'null') {
          streamKey = '$streamKey.$namespace';
        }
        if (startByte != null && int.parse(startByte) > 0) {
          _cleanUp(streamId);
        }

        var notificationKey =
            '@$receiver:$streamKey $currentAtSign:$streamId:$fileName:$fileLength';

        await _notify(receiver,
            AtSecondaryServerImpl.getInstance().currentAtSign, notificationKey);
        StreamManager.senderSocketMap[streamId] = atConnection;
        break;
      case 'resume':
        var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
        //receiver = AtUtils.formatAtSign(receiver);
        final sender = receiver;
        var notificationKey = '@$sender:stream_resume $streamId:$startByte';
        logger.finer('inside stream resume $notificationKey');
        await _notify(receiver, currentAtSign, notificationKey);
        break;
    }
    response.isStream = true;
  }

  Future<void> _notify(forAtSign, atSign, key) async {
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
    var notificationId =
        await NotificationManager.getInstance().notify(atNotification);
    logger.finer('notification_id : $notificationId');
  }

  void _cleanUp(String streamId) {
    final receiverConnection = StreamManager.receiverSocketMap[streamId];
    if (receiverConnection != null) {
      receiverConnection.getSocket().destroy();
    }
    final senderConnection = StreamManager.senderSocketMap[streamId];
    if (senderConnection != null) {
      senderConnection.getSocket().destroy();
    }
    StreamManager.receiverSocketMap.remove(streamId);
    StreamManager.senderSocketMap.remove(streamId);
  }
}
