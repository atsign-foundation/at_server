import 'dart:io';
import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:uuid/uuid.dart';

class OutboundConnectionImpl<T extends Socket>
    extends OutboundSocketConnection {
  static int? outboundIdleTime =
      AtSecondaryServerImpl.getInstance().serverContext!.outboundIdleTimeMillis;

  OutboundConnectionImpl(T socket, String? toAtSign) : super(socket) {
    var sessionId = '_${Uuid().v4()}';
    metaData = OutboundConnectionMetadata()
      ..sessionID = sessionId
      ..toAtSign = toAtSign
      ..created = DateTime.now().toUtc()
      ..isCreated = true;
  }

  int _getIdleTimeMillis() {
    var lastAccessedTime = metaData.lastAccessed;
    lastAccessedTime ??= metaData.created;
    var currentTime = DateTime.now().toUtc();
    return currentTime.difference(lastAccessedTime!).inMilliseconds;
  }

  bool _isIdle() {
    return _getIdleTimeMillis() > outboundIdleTime!;
  }

  @override
  bool isInValid() {
    return _isIdle() || metaData.isClosed || metaData.isStale;
  }

  @override
  Future<void> close() async {
    // Over-riding BaseConnection.close() (which calls socket.close()), as only want to change
    // behaviour for outbound connections for now, not inbound connections

    // Some defensive code just in case we accidentally call close multiple times
    if (metaData.isClosed) {
      return;
    }

    try {
      var socket = underlying;
      var address = socket.remoteAddress;
      var port = socket.remotePort;
      socket.destroy();
      logger.finer('$address:$port Disconnected');
      metaData.isClosed = true;
    } on Exception {
      metaData.isStale = true;
      // Ignore exception on a connection close
    } on Error {
      metaData.isStale = true;
      // Ignore error on a connection close
    }
  }

  @override
  void write(String data) {
    super.write(data);
    logger.info(logger.getAtConnectionLogMessage(
        metaData, 'SENT: ${BaseSocketConnection.truncateForLogging(data)}'));
  }
}
