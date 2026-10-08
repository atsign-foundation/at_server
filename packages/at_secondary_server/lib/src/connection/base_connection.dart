import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// Base class for common socket operations
abstract class BaseSocketConnection<T extends Socket> extends AtConnection {
  final T _socket;
  @override
  late AtConnectionMetaData metaData;
  late AtSignLogger logger;

  BaseSocketConnection(this._socket) {
    logger = AtSignLogger(runtimeType.toString());
    _socket.setOption(SocketOption.tcpNoDelay, true);
  }

  @override
  Future<void> close() async {
    try {
      var address = underlying.remoteAddress;
      var port = underlying.remotePort;
      await _socket.close();
      logger.finer('$address:$port Disconnected');
      metaData.isClosed = true;
    } on Exception {
      metaData.isStale = true;
      // Ignore exception on a connection close
    } on Error {
      metaData.isStale = true;
      // Ignore error on a connection close
    }
  }

  @override
  T get underlying => _socket;

  @override
  Future<void> write(String data) async {
    if (isInValid()) {
      throw ConnectionInvalidException('Connection is invalid');
    }
    try {
      underlying.write(data);
      metaData.lastAccessed = DateTime.timestamp();
    } catch (e) {
      metaData.isStale = true;
      logger.severe('write caught ${e.toString()}');
      throw AtIOException(e.toString());
    }
  }

  /// The C0 and C1 control characters, and DEL.
  static final RegExp _controlCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  /// [toLog] cut to [cutOffAfter] characters, with every control character
  /// written as a visible escape (`\r`, `\x1b`), so that each log record
  /// stays on one line of printable text.
  static String sanitiseForLogging(String toLog, {int cutOffAfter = 2100}) {
    if (toLog.length > cutOffAfter) {
      toLog =
          '${toLog.substring(0, cutOffAfter)} [truncated, ${toLog.length - cutOffAfter} more chars]';
    }
    return toLog.replaceAllMapped(
        _controlCharacters, (m) => _escape(m[0]!.codeUnitAt(0)));
  }

  static String _escape(int codeUnit) => switch (codeUnit) {
        0x09 => r'\t',
        0x0a => r'\n',
        0x0d => r'\r',
        _ => '\\x${codeUnit.toRadixString(16).padLeft(2, '0')}',
      };
}
