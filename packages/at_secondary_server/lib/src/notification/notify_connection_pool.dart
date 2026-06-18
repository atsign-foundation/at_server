import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' show SecondaryAddressFinder;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_utils/at_logger.dart';

/// Class to maintains the pool of outbound connections for notifying.
class NotifyConnectionsPool {
  static final logger = AtSignLogger('NotifyConnectionPool');

  static const int defaultPoolSize = 200;

  late final OutboundClientPool _outboundClientPool;
  final OutboundConnectionFactory outboundConnectionFactory;
  final SecondaryAddressFinder secondaryAddressFinder;

  /// Server-scoped collaborators injected into each [OutboundClient]. Wired late
  /// (after AtCacheManager and the signing key exist) at the composition root.
  /// The narrow [cachePublicKey] callback (rather than the whole AtCacheManager)
  /// breaks the OutboundClient <-> AtCacheManager dependency cycle.
  late Future<void> Function(String name, AtData data) cachePublicKey;
  late Atsign currentAtSign;
  dynamic signingKey;
  late AtKeyValueStore<String, AtData, AtMetaData?> keyStore;

  NotifyConnectionsPool(
    this.secondaryAddressFinder,
    this.outboundConnectionFactory, {
    int poolSize = defaultPoolSize,
  }) {
    _outboundClientPool = OutboundClientPool(size: poolSize);
  }

  OutboundClientPool get outboundClientPool => _outboundClientPool;

  int get size => _outboundClientPool.size;

  set size(int s) => _outboundClientPool.size = s;

  int getCapacity() {
    _outboundClientPool.clearInvalidClients();
    return _outboundClientPool.getCapacity()! -
        _outboundClientPool.getCurrentSize();
  }

  Future<OutboundClient> getOutboundClient(
    String toAtSign, {
    bool connect = true,
  }) async {
    _outboundClientPool.clearInvalidClients();
    var inboundConnection = DummyInboundConnection();
    var client = _outboundClientPool.get(toAtSign, inboundConnection);

    if (client != null) {
      if (logger.isLoggable('info')) {
        logger.info(
            'retrieved outbound client to $toAtSign (handshake: true) from pool');
      }
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
    var newClient = OutboundClient(
      inboundConnection,
      toAtSign,
      secondaryAddressFinder,
      true,
      outboundConnectionFactory,
      cachePublicKey,
      currentAtSign,
      signingKey,
      keyStore,
    );
    if (connect) {
      await newClient.connect();
    } else {
      logger.warning('Created new client but not connecting it');
    }
    _outboundClientPool.add(newClient);
    logger.info(
        'Created new outbound client to $toAtSign (handshake: true) and added to pool');
    return newClient;
  }
}
