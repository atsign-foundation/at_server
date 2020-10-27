import 'dart:io';

import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_server_spec/at_server_spec.dart';

// Represent an OutboundConnection to another user's secondary server.
abstract class OutboundConnection extends BaseConnection {
  OutboundConnection(Socket socket) : super(socket);
}

/// Metadata information for [OutboundConnection]
class OutboundConnectionMetadata extends AtConnectionMetaData {
  String toAtSign;
  bool isHandShakeSuccess = false;
}
