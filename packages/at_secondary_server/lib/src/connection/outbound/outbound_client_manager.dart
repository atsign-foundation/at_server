import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Class to retrieve and manage [OutboundClient] from [OutboundClientPool]
class OutboundClientManager {
  static final OutboundClientManager _singleton =
      OutboundClientManager._internal();

  var logger = AtSignLogger('OutboundClientManager');

  static const int defaultPoolSize = 10;

  final OutboundClientPool _pool = OutboundClientPool(size: defaultPoolSize);

  OutboundClientManager._internal();

  factory OutboundClientManager.getInstance() {
    return _singleton;
  }
  @visibleForTesting
  bool closed = false;

  set poolSize (int s) => _pool.size = s;
  int get poolSize => _pool.size;

  /// If the pool is already initialized, checks and returns an outbound client if it is already in pool.
  /// Otherwise clears idle clients and creates a new outbound client if the pool has capacity. Returns null if pool does not have capacity.
  ///  If the pool is not initialized, initializes the pool with [defaultPoolSize] and creates a new client
  ///  Throws a [OutboundConnectionLimitException] if connection cannot be added because pool has reached max capacity
  OutboundClient getClient(
      String toAtSign, InboundConnection inboundConnection,
      {bool isHandShake = true}) {
    if (closed) {
      throw StateError('getClient called but we are in closed state');
    }
    _pool.clearInvalidClients();
    // Get OutboundClient for a given atSign and InboundConnection
    OutboundClient? client = _pool.get(toAtSign, inboundConnection, isHandShake: isHandShake);

    if (client != null) {
      logger.finer('retrieved outbound client from pool to $toAtSign');
      return client;
    }

    if (!_pool.hasCapacity()) {
      OutboundClient? evictedClient = _pool.removeLeastRecentlyUsed();
      logger.info("Evicted LRU client from pool : $evictedClient");
      if (!_pool.hasCapacity()) {
        throw OutboundConnectionLimitException('max limit reached on outbound pool');
      }
    }

    // No existing client found, and Pool has capacity - create a new client
    var newClient = OutboundClient(inboundConnection, toAtSign);
    _pool.add(newClient);
    return newClient;
  }

  close() {
    closed = true;
    _pool.close();
  }

  int getActiveConnectionSize() {
    return _pool.getActiveConnectionSize();
  }
}
