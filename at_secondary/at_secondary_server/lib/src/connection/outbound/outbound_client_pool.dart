import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Pool to hold [OutboundClient]
class OutboundClientPool {
  late int _size;

  late List<OutboundClient> _clients;

  void init(int size) {
    _size = size;
    _clients = [];
  }

  bool hasCapacity() {
    return _clients.length < _size;
  }

  /// Removes the least recently used OutboundClient from the pool. Returns the removed client,
  /// or returns null if there are fewer than 2 items currently in the pool.
  OutboundClient? removeLeastRecentlyUsed() {
    if (_clients.length < 2) {
      return null;
    } else {
      _clients.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
      return _clients.removeAt(0);
    }
  }

  void add(OutboundClient outBoundClient) => _clients.add(outBoundClient);

  OutboundClient? get(String? toAtSign, InboundConnection inboundConnection,
      {bool isHandShake = true}) {
    //TODO should clearInvalid moved to a cron ?
    // e.g. 10 outbound clients are created. There are no calls to get(..) for a long time. these
    // clients will remain in the pool
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
    return _clients.length;
  }

  int getActiveConnectionSize() {
    var count = 0;
    for (var client in _clients) {
      if (!client.isInValid()) {
        count++;
      }
    }
    return count;
  }

  int? getCapacity() {
    return _size;
  }

  bool clearAllClients() {
    for (var client in _clients) {
      client.close();
    }
    _clients.clear();
    return true;
  }
}
