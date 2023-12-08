import 'dart:convert';
import 'dart:io';
import 'package:at_root_server/src/client/at_root_client_pool.dart';
import 'package:at_persistence_root_server/at_persistence_root_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_commons/at_commons.dart';

enum RootClientState {listening,closing,closed}

/// Represents Root Server client instance which contains socket on which a connection got established
class RootClient {
  late Socket _socket;
  String? _address;
  int? _port;
  static final _keyStoreManager = KeystoreManagerImpl();
  final _buffer = StringBuffer(capacity: 255);
  int notFoundCount = 0;
  late RootClientState state;

  RootClient(Socket s) {
    _socket = s;
    _address = _socket.remoteAddress.address;
    _port = _socket.remotePort;
    RootClientPool().add(this);
    _socket.listen(_messageHandler,
        onError: _errorHandler, onDone: _finishedHandler);
    state = RootClientState.listening;
  }

  var logger = AtSignLogger('RootClient');

  /// _messageHandler perform operations on the incoming data from client
  ///  Return type - void
  ///  @param - data : data received from client over the socket
  Future<void> _messageHandler(data) async {
    try {
      logger.finest('${_address}:${_port} In root client _messagehandler');
      var message = utf8.decode(data);
      message = message.toLowerCase();
      _buffer.append(message);
      var lookupPayload = _buffer.getData()!.trim();
      if (lookupPayload == '@exit') {
        _finishedHandler();
        return;
      } else {
        if (_buffer.isEnd()) {
          var result = await _keyStoreManager
              .getKeyStore()
              .get(lookupPayload);
          logger.info('${_address}:${_port} Looked up: $lookupPayload | Found: $result');

          if (result == null) {
            notFoundCount++;
            if (notFoundCount > 1) {
              // If we've already had at least one lookup of a non-existent atSign
              // then we will wait a few seconds before responding
              await Future.delayed(Duration(seconds: 3));
            }

            if (notFoundCount > 2) {
              // And if we've already had at least two lookups of a non-existent
              // atSign then we will terminate the connection
              _finishedHandler();
              return;
            }
          }
          result ??= 'null';
          write(result + '\r\n@');
          _buffer.clear();
        }
      }
    } on Exception catch (exception) {
      logger.severe('${_address}:${_port} _messageHandler | $exception');
      _socket.destroy();
    } catch (error) {
      _errorHandler(error.toString());
    }
  }

  /// _errorHandler perform required actions when ever there is an error
  ///  Return type - void
  ///  @param - error : error string
  void _errorHandler(error) {
    if (state == RootClientState.listening) {
      logger.severe('${_address}:${_port} Error: $error');
      removeClient(this);
    }
  }

  /// _finishedHandler close the client connection and remove from client pool
  ///  Return type - void
  void _finishedHandler() {
    if (state == RootClientState.listening) {
      logger.info('${_address}:${_port} Disconnected');
      removeClient(this);
    }
  }

  /// write - Writes received message to the client socket
  /// Return type - void
  /// @param - message : Message to write on to the client socket
  void write(String message) {
    _socket.write(message);
    _socket.flush();
  }

  /// removeClient - close and remove client
  /// return type - void
  /// @param - rootClient - Instance of RootClient
  void removeClient(RootClient rootClient) {
    state = RootClientState.closing;
    rootClient._socket.destroy();
    RootClientPool().remove(rootClient);
    state = RootClientState.closed;
  }
}
