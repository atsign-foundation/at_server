import 'dart:io';

import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';

class InboundConnectionImpl extends BaseConnection
    implements InboundConnection {
  @override
  bool? isMonitor = false;

  /// This contains the value of the atsign initiated the connection
  @override
  String? initiatedBy;
  static int? inboundIdleTime = AtSecondaryServerImpl.getInstance().serverContext!.inboundIdleTimeMillis;

  InboundConnectionImpl(Socket? socket, String? sessionId) : super(socket) {
    metaData = InboundConnectionMetadata()
      ..sessionID = sessionId
      ..created = DateTime.now().toUtc()
      ..isCreated = true;
  }

  /// Returns true if the underlying socket is not null and socket's remote address and port match.
  @override
  bool equals(InboundConnection connection) {
    var result = false;
    if (getSocket().remoteAddress.address ==
            connection.getSocket().remoteAddress.address &&
        getSocket().remotePort == connection.getSocket().remotePort) {
      result = true;
    }
    return result;
  }

  @override
  bool isInValid() {
    return _isIdle() || getMetaData().isClosed || getMetaData().isStale;
  }

  /// Get the idle time of the inbound connection since last write operation
  int _getIdleTimeMillis() {
    var lastAccessedTime = getMetaData().lastAccessed;
    // if lastAccessedTime is not set, use created time
    lastAccessedTime ??= getMetaData().created;
    var currentTime = DateTime.now().toUtc();
    return currentTime.difference(lastAccessedTime!).inMilliseconds;
  }

  /// Returns true if the client's idle time is greater than configured idle time.
  /// false otherwise
  bool _isIdle() {
    return _getIdleTimeMillis() > inboundIdleTime!;
  }

  @override
  void acceptRequests(Function(String, InboundConnection) callback,
      Function(List<int>, InboundConnection) streamCallBack) {
    var listener = InboundMessageListener(this);
    listener.listen(callback, streamCallBack);
  }

  @override
  Socket? receiverSocket;

  bool? isStream;
}
