import 'dart:collection';

import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// Pool to hold [InboundConnection]
class InboundConnectionPool {
  late int _size;
  final String serverAtSign;
  final List<InboundConnection> _connections = [];

  InboundConnectionPool({required this.serverAtSign, required int size}) {
    _size = size;
  }

  var logger = AtSignLogger('InboundConnectionPool');

  void resize(int newSize) {
    _size = newSize;
  }

  Map mdSnippet(InboundConnectionMetadata md) => {
        'from': md.isAuthenticated ? serverAtSign : md.fromAtSign,
        'created': md.created?.toIso8601String(),
        'lastAccessed': md.lastAccessed?.toIso8601String()
      };

  Map<String, dynamic> getStats({required bool detailed}) {
    int selfAuthCount = 0;
    List selfAuthList = [];

    int polAuthCount = 0;
    List polAuthList = [];

    int unAuthCount = 0;
    List unAuthList = [];

    for (final c in _connections) {
      InboundConnectionMetadata md = c.metaData as InboundConnectionMetadata;
      if (md.isAuthenticated) {
        selfAuthCount++;
        selfAuthList.add(mdSnippet(md));
      } else if (c.metaData.isPolAuthenticated) {
        polAuthCount++;
        polAuthList.add(mdSnippet(md));
      } else {
        unAuthCount++;
        unAuthList.add(mdSnippet(md));
      }
    }
    if (detailed) {
      return {
        'total': selfAuthCount + polAuthCount + unAuthCount,
        'self': {'count': selfAuthCount, 'list': selfAuthList},
        'other': {'count': polAuthCount, 'list': polAuthList},
        'anon': {'count': unAuthCount, 'list': unAuthList},
      };
    } else {
      return {
        'total': selfAuthCount + polAuthCount + unAuthCount,
        'self': selfAuthCount,
        'other': polAuthCount,
        'anon': unAuthCount,
      };
    }
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
    // clearInvalidConnections needs to never throw an exception, as the entire server will hang if it does
    try {
      var invalidConnections = [];
      //dart doesn't support iterator.remove(). So use forEach + removeWhere
      for (var connection in _connections.toList()) {
        if (connection.isInValid()) {
          invalidConnections.add(connection);
        }
      }
      // clearInvalidConnections needs to never throw an exception, so we're going to do all of the connection close() calls separately here
      for (var connection in invalidConnections) {
        try {
          connection.close();
        } catch (e) {
          logger.severe(
              "clearInvalidConnections: Exception while closing connection: $e");
        }
      }

      _connections.removeWhere((client) => invalidConnections.contains(client));
      _checkWarningStatesOnRemove();
    } catch (e) {
      logger.severe(
          "clearInvalidConnections: Caught (and swallowing) exception $e");
    }
  }

  int getCurrentSize() {
    return _connections.length;
  }

  int getCapacity() => _size;

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
      logger.warning('InboundConnectionPool >= 85% of $_size');
      passedEightyFivePercent = true;
    }
    if (_connections.length >= _size * 0.95 && !passedNinetyFivePercent) {
      logger.severe('InboundConnectionPool >= 95% of $_size');
      passedNinetyFivePercent = true;
    }
  }

  void _checkWarningStatesOnRemove() {
    if (_connections.length < _size * 0.95 && passedNinetyFivePercent) {
      logger.info('InboundConnectionPool < 95% of $_size');
      passedNinetyFivePercent = false;
    }
    if (_connections.length < _size * 0.85 && passedEightyFivePercent) {
      logger.info('InboundConnectionPool < 85% of $_size');
      passedEightyFivePercent = false;
    }
  }

  /// Returns the number of active monitor connections.
  int getMonitorConnectionSize() {
    var count = 0;
    getConnections().forEach((connection) {
      if (!connection.isInValid() && connection.isMonitor!) {
        count++;
      }
    });

    return count;
  }

  /// Returns the number of active connections.
  int getActiveConnectionSize() {
    var count = 0;
    getConnections().forEach((connection) {
      if (!connection.isInValid()) {
        count++;
      }
    });

    return count;
  }

  /// Return total capacity of connection manager of connection pool.
  int totalConnectionSize() {
    return getConnections().length;
  }
}
