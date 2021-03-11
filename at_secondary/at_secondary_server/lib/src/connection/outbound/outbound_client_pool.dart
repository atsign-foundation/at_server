import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Pool to hold [OutboundClient]
class OutboundClientPool {
  int _size;

  List<OutboundClient> _clients;

  void init(int size) {
    _size = size;
    _clients = [];
  }

  bool hasCapacity() {
    return _clients.length < _size;
  }

  void add(OutboundClient outBoundClient) => _clients.add(outBoundClient);

  OutboundClient get(String toAtSign, InboundConnection inboundConnection,
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
    _clients.forEach((client) {
      if (client.isInValid()) {
        invalidClients.add(client);
        client.close();
      }
    });
    _clients.removeWhere((client) => invalidClients.contains(client));
  }

  int getCurrentSize() {
    return _clients.length;
  }

  int getActiveConnectionSize() {
    var count = 0;
    _clients.forEach((client) {
      if (!client.isInValid()) {
        count++;
      }
    });
    return count;
  }

  int getCapacity() {
    return _size;
  }

  bool clearAllClients() {
    _clients.forEach((client) {
      client.close();
    });
    _clients.clear();
    return true;
  }
}
