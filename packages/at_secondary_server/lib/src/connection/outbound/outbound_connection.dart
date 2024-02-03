import 'dart:io';

import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_server_spec/at_server_spec.dart';

// Represent an OutboundConnection to another atServer
abstract class OutboundSocketConnection<T extends Socket> extends BaseSocketConnection {
  OutboundSocketConnection(T socket) : super(socket);
}

/// Metadata information for [OutboundSocketConnection]
class OutboundConnectionMetadata extends AtConnectionMetaData {
  String? toAtSign;
  bool isHandShakeSuccess = false;
}
