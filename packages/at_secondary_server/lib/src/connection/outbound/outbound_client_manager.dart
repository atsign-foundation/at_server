import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_pool.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';
import 'package:mutex/mutex.dart';

/// Class to retrieve and manage [OutboundClient] from [OutboundClientPool]
class OutboundClientManager {
  var logger = AtSignLogger('OutboundClientManager');

  static const int defaultPoolSize = 200;

  late final OutboundClientPool _pool;

  OutboundClientManager(
    this.secondaryAddressFinder,
    this.outboundConnectionFactory, {
    int poolSize = defaultPoolSize,
  }) {
    _pool = OutboundClientPool(size: poolSize);
  }

  @visibleForTesting
  bool closed = false;

  @visibleForTesting
  SecondaryAddressFinder secondaryAddressFinder;
  final OutboundConnectionFactory outboundConnectionFactory;

  set poolSize(int s) => _pool.size = s;

  int get poolSize => _pool.size;

  /// One mutex per pool key. Looking a client up in the pool and adding a
  /// newly created one back are separated by an await — [OutboundClient.connect]
  /// — so without this two callers that both miss for the same key each
  /// create and add a client for it, and the pool then holds two connections
  /// where the caller asked for one shared connection.
  ///
  /// Per key rather than one lock for the whole manager, so that connecting
  /// to one atSign does not hold up connecting to another.
  ///
  /// This lock covers duplicate creation for one key. Capacity across all
  /// keys is handled separately, by [OutboundClientPool.tryReserve], because
  /// a lock that could cover it would have to span [OutboundClient.connect]
  /// and would serialise connecting to unrelated atSigns.
  final Map<(String, Object, bool), _MutexRef> _getClientMutexes = {};

  /// Which callers contend for the same lock, following the rule
  /// [OutboundClientPool.get] matches on.
  ///
  /// Any [DummyInboundConnection] matches any other, so every caller holding
  /// a dummy shares one lock. Every other kind of connection matches on
  /// something no two simultaneously live inbound connections share — a
  /// remote address and port, or a web socket — so the connection object
  /// itself separates them.
  Object _lockScope(InboundConnection inboundConnection) =>
      inboundConnection is DummyInboundConnection
          ? DummyInboundConnection
          : inboundConnection;

  /// If the pool is already initialized, checks and returns an outbound client if it is already in pool.
  /// Otherwise clears idle clients and creates a new outbound client if the pool has capacity. Returns null if pool does not have capacity.
  ///  If the pool is not initialized, initializes the pool with [defaultPoolSize] and creates a new client
  ///  Throws a [OutboundConnectionLimitException] if connection cannot be added because pool has reached max capacity
  Future<OutboundClient> getClient(
    String toAtSign,
    InboundConnection inboundConnection, {
    required bool handshakeRequired,
    bool connect = true,
  }) async {
    if (closed) {
      throw StateError('getClient called but we are in closed state');
    }
    final lockKey =
        (toAtSign, _lockScope(inboundConnection), handshakeRequired);
    final mutexRef = _getClientMutexes.putIfAbsent(lockKey, _MutexRef.new);
    mutexRef.waiters++;
    try {
      return await mutexRef.mutex.protect(() => _getClient(
            toAtSign,
            inboundConnection,
            handshakeRequired: handshakeRequired,
            connect: connect,
          ));
    } finally {
      mutexRef.waiters--;
      if (mutexRef.waiters == 0) {
        _getClientMutexes.remove(lockKey);
      }
    }
  }

  /// Looks the client up, creating and pooling one if there is no match.
  /// Runs under this key's entry in [_getClientMutexes].
  Future<OutboundClient> _getClient(
    String toAtSign,
    InboundConnection inboundConnection, {
    required bool handshakeRequired,
    bool connect = true,
  }) async {
    _pool.clearInvalidClients();
    // Get OutboundClient for a given atSign and InboundConnection
    OutboundClient? client =
        _pool.get(toAtSign, inboundConnection, isHandShake: handshakeRequired);

    if (client != null) {
      if (logger.isLoggable('info')) {
        logger.info(
            'retrieved outbound client to $toAtSign (handshake: $handshakeRequired) from pool');
      }
      return client;
    }

    // Take the slot before connecting. Reserve, evict and refuse run with no
    // await between them, so a caller for another pool key -- holding a
    // different lock -- cannot claim the same slot while this one is inside
    // connect().
    if (!_pool.tryReserve()) {
      OutboundClient? evictedClient = _pool.removeLeastRecentlyUsed();
      logger.info("Evicted LRU client from pool : $evictedClient");
      if (!_pool.tryReserve()) {
        throw OutboundConnectionLimitException(
            'max limit reached on outbound pool');
      }
    }

    var reserved = true;
    try {
      // No existing client found, and Pool has capacity - create a new client
      var newClient = OutboundClient(
        inboundConnection,
        toAtSign,
        secondaryAddressFinder,
        handshakeRequired,
        outboundConnectionFactory,
      );
      if (connect) {
        await newClient.connect();
      } else {
        logger.warning('Created new client but not connecting it');
      }
      _pool.addReserved(newClient);
      reserved = false;
      logger.info(
          'Created new outbound client to $toAtSign (handshake: $handshakeRequired) and added to pool');
      return newClient;
    } finally {
      // A connect that threw must not leave the pool permanently smaller.
      if (reserved) {
        _pool.releaseReservation();
      }
    }
  }

  int getActiveConnectionSize() {
    return _pool.getActiveConnectionSize();
  }

  @visibleForTesting
  int get pendingGetClientLocks => _getClientMutexes.length;
}

/// Mutable holder for a per-pool-key mutex and the number of callers waiting
/// on it, so an entry can be dropped once nobody is contending for that key.
class _MutexRef {
  final Mutex mutex = Mutex();
  int waiters = 0;
}
