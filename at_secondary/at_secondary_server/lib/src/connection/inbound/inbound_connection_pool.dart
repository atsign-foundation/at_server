import 'dart:collection';

import 'package:at_server_spec/at_server_spec.dart';

/// Pool to hold [InboundConnection]
class InboundConnectionPool {
  static final InboundConnectionPool _singleton =
      InboundConnectionPool._internal();
  int? _size;

  factory InboundConnectionPool.getInstance() {
    return _singleton;
  }

  InboundConnectionPool._internal();

  late List<InboundConnection> _connections;

  void init(int? size) {
    _size = size;
    _connections = [];
  }

  bool hasCapacity() {
    return _connections.length < _size!;
  }

  void add(InboundConnection inboundConnection) {
    _connections.add(inboundConnection);
  }

  void clearInvalidConnections() {
    var invalidConnections = [];
    //dart doesn't support iterator.remove(). So use forEach + removeWhere
    _connections.forEach((connection) {
      if (connection.isInValid()) {
        invalidConnections.add(connection);
        connection.close();
      }
    });
    _connections.removeWhere((client) => invalidConnections.contains(client));
  }

  int getCurrentSize() {
    return _connections.length;
  }

  int? getCapacity() {
    return _size;
  }

  bool clearAllConnections() {
    _connections.forEach((connection) {
      connection.close();
    });
    _connections.clear();
    return true;
  }

  UnmodifiableListView<InboundConnection> getConnections() {
    return UnmodifiableListView<InboundConnection>(_connections);
  }
}
