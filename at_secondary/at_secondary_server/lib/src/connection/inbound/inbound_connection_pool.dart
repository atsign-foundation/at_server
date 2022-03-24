import 'dart:collection';

import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// Pool to hold [InboundConnection]
class InboundConnectionPool {
  static final InboundConnectionPool _singleton = InboundConnectionPool._internal();
  late int _size;

  factory InboundConnectionPool.getInstance() {
    return _singleton;
  }

  InboundConnectionPool._internal();

  var logger = AtSignLogger('InboundConnectionPool');

  late List<InboundConnection> _connections;

  void init(int size) {
    _size = size;
    _connections = [];
  }

  bool hasCapacity() {
    return _connections.length < _size;
  }

  bool passedEightyFivePercent = false;
  bool passedNinetyFivePercent = false;
  void add(InboundConnection inboundConnection) {
    _connections.add(inboundConnection);
    _checkWarningStatesOnAdd();
  }

  void remove(InboundConnection inboundConnection) {
    _connections.remove(inboundConnection);
    _checkWarningStatesOnRemove();
  }

  void clearInvalidConnections() {
    var invalidConnections = [];
    //dart doesn't support iterator.remove(). So use forEach + removeWhere
    for (var connection in _connections.toList()) {
      if (connection.isInValid()) {
        invalidConnections.add(connection);
        connection.close();
      }
    }
    _connections.removeWhere((client) => invalidConnections.contains(client));
    _checkWarningStatesOnRemove();
  }

  int getCurrentSize() {
    return _connections.length;
  }

  int? getCapacity() {
    return _size;
  }

  bool clearAllConnections() {
    for (var connection in _connections.toList()) {
      connection.close();
    }
    _connections.clear();
    _checkWarningStatesOnRemove();
    return true;
  }

  UnmodifiableListView<InboundConnection> getConnections() {
    return UnmodifiableListView<InboundConnection>(_connections);
  }

  void _checkWarningStatesOnAdd() {
    if (_connections.length >= _size * 0.85 && !passedEightyFivePercent) {
      logger.warning('InboundConnectionPool >= 85% full');
      passedEightyFivePercent = true;
    }
    if (_connections.length >= _size * 0.95 && !passedNinetyFivePercent) {
      logger.severe('InboundConnectionPool >= 95% full');
      passedNinetyFivePercent = true;
    }
  }

  void _checkWarningStatesOnRemove() {
    if (_connections.length < _size * 0.95 && passedNinetyFivePercent) {
      logger.info('InboundConnectionPool < 95% full');
      passedNinetyFivePercent = false;
    }
    if (_connections.length < _size * 0.85 && passedEightyFivePercent) {
      logger.info('InboundConnectionPool < 85% full');
      passedEightyFivePercent = false;
    }
  }
}
