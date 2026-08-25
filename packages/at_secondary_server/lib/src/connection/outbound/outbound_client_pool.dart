import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

/// Pool to hold [OutboundClient]
class OutboundClientPool {
  var logger = AtSignLogger('OutboundClientPool');

  int size;
  final List<OutboundClient> _clients = [];

  OutboundClientPool({this.size = 10});

  @visibleForTesting
  bool closed = false;

  /// Slots taken by a caller that is creating a client but has not added it
  /// yet. Creating one means awaiting [OutboundClient.connect], and without
  /// counting the gap two callers -- who hold different locks, because the
  /// lock is per pool key -- each see the same free slot and both create.
  ///
  /// Reserving, evicting and refusing all happen in one synchronous run, so
  /// they are atomic on Dart's single event loop without a lock of their own,
  /// and connect() still runs unlocked: connecting to one atSign does not
  /// hold up connecting to another.
  int _reserved = 0;

  /// Slots taken but not yet filled. [NotifyConnectionsPool.getCapacity]
  /// subtracts these, since a reserved slot is not free.
  int get reservedSize => _reserved;

  /// Whether a slot is free right now.
  ///
  /// Production code must take a slot with [tryReserve] instead. Asking this
  /// and adding later is the check-then-add race the reservation exists to
  /// close: creating a client awaits its connect, and another caller can take
  /// the slot in between.
  @visibleForTesting
  bool hasCapacity() {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    return _clients.length + _reserved < size;
  }

  /// Takes a slot if one is free. A caller that gets true must later call
  /// exactly one of [addReserved] or [releaseReservation].
  bool tryReserve() {
    if (closed) {
      throw StateError('tryReserve() called, but we are in closed state');
    }
    if (_clients.length + _reserved >= size) {
      return false;
    }
    _reserved++;
    return true;
  }

  /// Gives back a slot taken by [tryReserve] whose client never arrived.
  void releaseReservation() {
    if (_reserved > 0) {
      _reserved--;
    }
  }

  /// Adds the client a [tryReserve] slot was taken for.
  void addReserved(OutboundClient outBoundClient) {
    releaseReservation();
    add(outBoundClient);
  }

  /// Removes the least recently used OutboundClient from the pool and closes
  /// it. Returns the removed client, or null if there are fewer than 2 items
  /// currently in the pool, or if every candidate has a request in flight.
  ///
  /// Closing here is what releases the socket: the pool holds the last
  /// reference to an evicted client, since both
  /// [OutboundClientManager] and [NotifyConnectionsPool] log it and drop it.
  ///
  /// Clients with an exchange in flight are skipped rather than evicted.
  /// [OutboundClient.lastUsed] is stamped when an exchange finishes, so a
  /// client that has just begun a long request is exactly the one this method
  /// would otherwise pick — and closing it would destroy the socket under the
  /// caller waiting on it.
  OutboundClient? removeLeastRecentlyUsed() {
    if (closed) {
      throw StateError(
          'removeLeastRecentlyUsed() called, but we are in closed state');
    }
    if (_clients.length < 2) {
      return null;
    }
    _clients.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    var index = _clients.indexWhere((client) => !client.isBusy);
    if (index < 0) {
      logger.info('removeLeastRecentlyUsed: every pooled client has a request'
          ' in flight; not evicting');
      return null;
    }
    var evicted = _clients.removeAt(index);
    // Never throw from here: callers evict while deciding whether they have
    // capacity, and an exception would fail a request that has nothing to do
    // with the client being closed.
    try {
      evicted.close();
    } catch (e) {
      logger.severe(
          'removeLeastRecentlyUsed: exception closing $evicted : $e');
    }
    return evicted;
  }

  // Returns a copy of the list of clients in this pool, sorted by lastUsed, ascending
  List<OutboundClient> clients() {
    if (closed) {
      throw StateError('clients() called, but we are in closed state');
    }
    _clients.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    return [..._clients];
  }

  void add(OutboundClient outBoundClient) {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    _clients.add(outBoundClient);
  }

  OutboundClient? get(String? toAtSign, InboundConnection inboundConnection,
      {bool isHandShake = true}) {
    if (closed) {
      throw StateError('get() called, but we are in closed state');
    }
    for (var client in _clients) {
      if (client.toAtSign == toAtSign &&
          client.isHandShakeDone == isHandShake &&
          client.inboundConnection.equals(inboundConnection)) {
        return client;
      }
    }
    return null;
  }

  /// Closes and removes every pooled client whose connection has gone bad.
  ///
  /// A client whose OUTBOUND socket is still good is left alone while an
  /// exchange is in flight. [OutboundClient.isInValid] ORs the two sides
  /// together, so it is also true when only the *inbound* connection has gone
  /// away -- which says nothing about the socket a caller is still reading
  /// from, and closing it there would destroy that socket underneath them.
  /// Such a client is picked up on a later pass, once the exchange has ended.
  ///
  /// A client whose outbound socket has itself gone is removed even when it
  /// looks busy: there is nothing left to protect, and leaving it would hand
  /// the next caller a dead connection.
  ///
  /// Never throws: callers run this while deciding whether they have
  /// capacity, and a failure to close one client must not fail their request.
  void clearInvalidClients() {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    var invalidClients = [];
    for (var client in _clients) {
      // Dead means closed or stale, NOT idle: a client waiting on a slow
      // peer has not been written to recently and so looks idle, and that is
      // precisely the exchange the busy check exists to protect.
      var outboundDead = client.outboundConnection == null ||
          client.outboundConnection!.metaData.isClosed ||
          client.outboundConnection!.metaData.isStale;
      if (client.isInValid() && !(client.isBusy && !outboundDead)) {
        invalidClients.add(client);
        try {
          client.close();
        } catch (e) {
          logger.severe('clearInvalidClients: exception closing $client : $e');
        }
      }
    }
    _clients.removeWhere((client) => invalidClients.contains(client));
  }

  int getCurrentSize() {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    return _clients.length;
  }

  int getActiveConnectionSize() {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    var count = 0;
    for (var client in _clients) {
      if (!client.isInValid()) {
        count++;
      }
    }
    return count;
  }

  int? getCapacity() {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    return size;
  }

  bool clearAllClients() {
    for (var client in _clients) {
      client.close();
    }
    _clients.clear();
    return true;
  }
}
