import 'dart:io';

import 'package:at_server_spec/at_server_spec.dart';

abstract class AtConnectionFactory {
  InboundConnection createSocketConnection(Socket socket, {String? sessionId});
  InboundConnection createWebSocketConnection(WebSocket socket, {String? sessionId});
}
