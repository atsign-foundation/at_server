import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// Base class for common socket operations
abstract class BaseSocketConnection<T extends Socket> extends AtConnection {
  late final T _socket;
  late AtConnectionMetaData metaData;
  late AtSignLogger logger;

  BaseSocketConnection(this._socket) {
    logger = AtSignLogger(runtimeType.toString());
    _socket.setOption(SocketOption.tcpNoDelay, true);
  }

  @override
  AtConnectionMetaData getMetaData() {
    return metaData;
  }

  @override
  Future<void> close() async {
    try {
      var address = getSocket().remoteAddress;
      var port = getSocket().remotePort;
      await _socket.close();
      logger.finer('$address:$port Disconnected');
      getMetaData().isClosed = true;
    } on Exception {
      getMetaData().isStale = true;
      // Ignore exception on a connection close
    } on Error {
      getMetaData().isStale = true;
      // Ignore error on a connection close
    }
  }

  @override
  T getSocket() {
    return _socket;
  }

  @override
  void write(String data) {
    if (isInValid()) {
      throw ConnectionInvalidException('Connection is invalid');
    }
    try {
      getSocket().write(data);
      getMetaData().lastAccessed = DateTime.now().toUtc();
    } on Exception catch (e) {
      getMetaData().isStale = true;
      logger.severe(e.toString());
      throw AtIOException(e.toString());
    }
  }

  static String truncateForLogging(String toLog, {int cutOffAfter = 2100}) {
    if (toLog.length > cutOffAfter) {
      toLog =
          '${toLog.substring(0, cutOffAfter)} [truncated, ${toLog.length - cutOffAfter} more chars]';
    }
    return toLog;
  }
}
