import 'package:at_root_server/src/client/at_root_client.dart';

class RootClientPool {
  static final RootClientPool _singleton = RootClientPool._internal();

  factory RootClientPool() {
    return _singleton;
  }

  RootClientPool._internal();

  static late List<RootClient> _clients;

  void init() {
    _clients = [];
  }

  /// add - add rootClient to the _clients list
  /// Return type - void
  /// @param - rootClient : Instance of RootClient
  void add(RootClient rootClient) {
    _clients.add(rootClient);
  }

  /// size - returns size of the _clients list
  /// Return type - int
  int size() {
    return _clients.length;
  }

  /// closeAll - removes all the clients from the _clients and closes socket connections
  ///  Return type - bool
  ///  close all the client sockets and remove from _clients list.
  bool closeAll() {
    _clients.forEach((client) => {client.removeClient(client)});
    return true;
  }

  /// remove - remove RootClient from _clients list
  /// Return type - void
  /// @param - rootClient : Instance of RootClient
  void remove(RootClient rootClient) {
    _clients.remove(rootClient);
  }
}
