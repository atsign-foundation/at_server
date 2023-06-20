import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:meta/meta.dart';

/// Pool to hold [OutboundClient]
class OutboundClientPool {
  int size;
  final List<OutboundClient> _clients = [];

  OutboundClientPool({this.size = 10});

  @visibleForTesting
  bool closed = false;

  bool hasCapacity() {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    return _clients.length < size;
  }

  /// Removes the least recently used OutboundClient from the pool. Returns the removed client,
  /// or returns null if there are fewer than 2 items currently in the pool.
  OutboundClient? removeLeastRecentlyUsed() {
    if (closed) {
      throw StateError(
          'removeLeastRecentlyUsed() called, but we are in closed state');
    }
    if (_clients.length < 2) {
      return null;
    } else {
      _clients.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
      return _clients.removeAt(0);
    }
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

  void clearInvalidClients() {
    if (closed) {
      throw StateError('add() called, but we are in closed state');
    }
    var invalidClients = [];
    for (var client in _clients) {
      if (client.isInValid()) {
        invalidClients.add(client);
        client.close();
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
