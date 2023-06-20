import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_utils/at_logger.dart';

/// Class to maintains the pool of outbound connections for notifying.
class NotifyConnectionsPool {
  static final NotifyConnectionsPool _singleton =
      NotifyConnectionsPool._internal();
  static final logger = AtSignLogger('NotifyConnectionPool');

  static const int defaultPoolSize = 50;

  final OutboundClientPool _outboundClientPool =
      OutboundClientPool(size: defaultPoolSize);
  OutboundClientPool get pool => _outboundClientPool;

  NotifyConnectionsPool._internal();

  factory NotifyConnectionsPool.getInstance() {
    return _singleton;
  }

  int get size => _outboundClientPool.size;
  set size(int s) => _outboundClientPool.size = s;

  int getCapacity() {
    _outboundClientPool.clearInvalidClients();
    return _outboundClientPool.getCapacity()! -
        _outboundClientPool.getCurrentSize();
  }

  OutboundClient get(String toAtSign) {
    _outboundClientPool.clearInvalidClients();
    var inboundConnection = DummyInboundConnection();
    var client = _outboundClientPool.get(toAtSign, inboundConnection);

    if (client != null) {
      logger.finer('retrieved outbound client from pool to $toAtSign');
      return client;
    }

    if (!_outboundClientPool.hasCapacity()) {
      OutboundClient? evictedClient =
          _outboundClientPool.removeLeastRecentlyUsed();
      logger.info("Evicted LRU client from pool : $evictedClient");
      if (!_outboundClientPool.hasCapacity()) {
        throw OutboundConnectionLimitException(
            'max limit ${_outboundClientPool.size} reached on outbound pool');
      }
    }

    // If client is null and pool has capacity, create a new OutboundClient and add it to the pool
    // and return it back
    var newClient = OutboundClient(inboundConnection, toAtSign);
    _outboundClientPool.add(newClient);
    return newClient;
  }
}
