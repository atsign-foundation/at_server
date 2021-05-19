import 'dart:io';
import 'package:at_commons/at_commons.dart';

// Represent an OutboundConnection to another user's secondary server.
abstract class OutboundConnection extends BaseConnection {
  OutboundConnection(Socket socket) : super(socket);
}

/// Metadata information for [OutboundConnection]
class OutboundConnectionMetadata extends AtConnectionMetaData {
  String toAtSign;
  bool isHandShakeSuccess = false;
}
