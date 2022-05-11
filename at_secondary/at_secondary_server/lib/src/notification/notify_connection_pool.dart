import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_utils/at_logger.dart';

/// Class to maintains the pool of outbound connections for notifying.
class NotifyConnectionsPool {
  static final NotifyConnectionsPool _singleton =
      NotifyConnectionsPool._internal();

  var logger = AtSignLogger('NotifyConnectionPool');

  late OutboundClientPool _pool;
  static const int defaultPoolSize = 50;

  bool isInitialised = false;

  int _size = defaultPoolSize;
  int get size => _size;

  NotifyConnectionsPool._internal();

  factory NotifyConnectionsPool.getInstance() {
    return _singleton;
  }

  void init(int size) {
    if (isInitialised) {
      return;
    }
    _size = size;
    isInitialised = true;
    _pool = OutboundClientPool();
    _pool.init(_size);
  }

  int getCapacity() {
    if (!isInitialised) {
      init(defaultPoolSize);
    }
    _pool.clearInvalidClients();
    return _pool.getCapacity()! - _pool.getCurrentSize();
  }

  OutboundClient get(String? toAtSign) {
    // Initialize the pool if not already done
    if (!isInitialised) {
      init(defaultPoolSize);
    }
    _pool.clearInvalidClients();
    var inboundConnection = DummyInboundConnection();
    var client = _pool.get(toAtSign, inboundConnection);

    if (client != null) {
      logger.finer('retrieved outbound client from pool to $toAtSign');
      return client;
    }

    if (!_pool.hasCapacity()) {
      OutboundClient? evictedClient = _pool.removeLeastRecentlyUsed();
      logger.info("Evicted LRU client from pool : $evictedClient");
      if (!_pool.hasCapacity()) {
        throw OutboundConnectionLimitException('max limit $_size reached on outbound pool');
      }
    }

    // If client is null and pool has capacity, create a new OutboundClient and add it to the pool
    // and return it back
    var newClient = OutboundClient(inboundConnection, toAtSign);
    _pool.add(newClient);
    return newClient;
  }
}
