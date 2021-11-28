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
}
