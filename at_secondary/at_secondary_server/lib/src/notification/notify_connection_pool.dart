import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_utils/at_logger.dart';

/// Class to maintains the pool of outbound connections for notifying.
class NotifyConnectionsPool {
  static final NotifyConnectionsPool _singleton =
  NotifyConnectionsPool._internal();

  NotifyConnectionsPool._internal();

  factory NotifyConnectionsPool.getInstance() {
    return _singleton;
  }

  var logger = AtSignLogger('NotifyConnectionPool');

  OutboundClientPool _pool;
  static const int default_pool_size = 5;

  bool isInitialised = false;

  void init(int size) {
    _pool = OutboundClientPool();
    _pool.init(size);
    isInitialised = true;
  }

  int getCapacity() {
    if (!isInitialised) {
      init(default_pool_size);
    }
    _pool.clearInvalidClients();
    return _pool.getCapacity() - _pool.getCurrentSize();
  }

  OutboundClient get(String toAtSign) {
    // Initialize the pool if not already done
    if (!isInitialised) {
      init(default_pool_size);
    }
    _pool.clearInvalidClients();
    var inboundConnection = DummyInboundConnection.getInstance();
    var client = _pool.get(toAtSign, inboundConnection);

    if (client != null) {
      logger.finer('retrieved outbound client from pool to ${toAtSign}');
      return client;
    }

    if (!_pool.hasCapacity()) {
      throw OutboundConnectionLimitException(
          'max limit reached on outbound pool');
    }

    // If client is null and pool has capacity, create a new OutboundClient and add it to the pool
    // and return it back
    if (client == null && _pool.hasCapacity()) {
      var newClient = OutboundClient(inboundConnection, toAtSign);
      _pool.add(newClient);
      return newClient;
    }
  }
}
