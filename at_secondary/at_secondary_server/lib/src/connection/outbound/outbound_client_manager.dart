import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// Class to retrieve and manage [OutboundClient] from [OutboundClientPool]
class OutboundClientManager {
  static final OutboundClientManager _singleton =
      OutboundClientManager._internal();

  var logger = AtSignLogger('OutboundClientManager');

  OutboundClientPool _pool;

  static const int default_pool_size = 10;

  bool isInitialised = false;

  OutboundClientManager._internal();

  factory OutboundClientManager.getInstance() {
    return _singleton;
  }

  /// Initialises outbound client pool with a given size.
  /// @param - size - Maximum clients the pool can hold
  void init(int size) {
    _pool = OutboundClientPool();
    _pool.init(size);
    isInitialised = true;
  }

  /// If the pool is already initialized, checks and returns an outbound client if it is already in pool.
  /// Otherwise clears idle clients and creates a new outbound client if the pool has capacity. Returns null if pool does not have capacity.
  ///  If the pool is not initialized, initializes the pool with [default_pool_size] and creates a new client
  ///  Throws a [OutboundConnectionLimitException] if connection cannot be added because pool has reached max capacity
  OutboundClient getClient(
      String toAtSign, InboundConnection inboundConnection) {
    // Initialize the pool if not already done
    if (!isInitialised) {
      init(default_pool_size);
    }
    _pool.clearInvalidClients();
    // Get OutboundClient for a given atSign and InboundConnection
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

    return null;
  }

  int getActiveConnectionSize() {
    return isInitialised ? _pool.getActiveConnectionSize() : 0;
  }
}
