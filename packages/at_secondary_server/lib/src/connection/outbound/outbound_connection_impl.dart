import 'dart:io';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:uuid/uuid.dart';

class OutboundConnectionImpl extends OutboundConnection {
  static int? outboundIdleTime =
      AtSecondaryServerImpl.getInstance().serverContext!.outboundIdleTimeMillis;

  OutboundConnectionImpl(Socket? socket, String? toAtSign) : super(socket) {
    var sessionId = '_' + Uuid().v4();
    metaData = OutboundConnectionMetadata()
      ..sessionID = sessionId
      ..toAtSign = toAtSign
      ..created = DateTime.now().toUtc()
      ..isCreated = true;
  }

  int _getIdleTimeMillis() {
    var lastAccessedTime = getMetaData().lastAccessed;
    lastAccessedTime ??= getMetaData().created;
    var currentTime = DateTime.now().toUtc();
    return currentTime.difference(lastAccessedTime!).inMilliseconds;
  }

  bool _isIdle() {
    return _getIdleTimeMillis() > outboundIdleTime!;
  }

  @override
  bool isInValid() {
    return _isIdle() || getMetaData().isClosed || getMetaData().isStale;
  }

  @override
  Future<void> close() async {
    // Over-riding BaseConnection.close() (which calls socket.close()), as only want to change
    // behaviour for outbound connections for now, not inbound connections

    // Some defensive code just in case we accidentally call close multiple times
    if (getMetaData().isClosed) {
      return;
    }

    try {
      var address = getSocket().remoteAddress;
      var port = getSocket().remotePort;
      var socket = getSocket();
      if (socket != null) {
        socket.destroy();
      }
      logger.finer('$address:$port Disconnected');
      getMetaData().isClosed = true;
    } on Exception {
      getMetaData().isStale = true;
      // Ignore exception on a connection close
    } on Error {
      getMetaData().isStale = true;
      // Ignore error on a connection close
    }
  }
}
