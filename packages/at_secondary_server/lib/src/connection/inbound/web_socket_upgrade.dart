import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String _acceptGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// Answers [request] with `101 Switching Protocols` and returns a
/// server-side WebSocket with the socket it runs over. No subprotocol and no
/// extension is negotiated, so a client that offers compression is sent
/// uncompressed frames.
///
/// A request that is not a WebSocket upgrade, or repeats one of its headers,
/// is answered `400`, and the returned future fails with a
/// [WebSocketException].
Future<(WebSocket, Socket)> upgradeToWebSocket(HttpRequest request) async {
  final HttpResponse response = request.response;
  if (!_isUpgradeRequest(request)) {
    response.statusCode = HttpStatus.badRequest;
    response.close().ignore();
    throw const WebSocketException('Invalid WebSocket upgrade request');
  }
  final String key = request.headers.value('Sec-WebSocket-Key')!;
  response
    ..statusCode = HttpStatus.switchingProtocols
    ..headers.add(HttpHeaders.connectionHeader, 'Upgrade')
    ..headers.add(HttpHeaders.upgradeHeader, 'websocket')
    ..headers.add('Sec-WebSocket-Accept',
        base64.encode(sha1.convert(latin1.encode('$key$_acceptGuid')).bytes))
    ..headers.contentLength = 0;
  final Socket socket = await response.detachSocket();
  return (WebSocket.fromUpgradedSocket(socket, serverSide: true), socket);
}

/// Whether [request] is a WebSocket upgrade with each of its headers once.
bool _isUpgradeRequest(HttpRequest request) {
  try {
    return WebSocketTransformer.isUpgradeRequest(request);
  } on HttpException {
    return false;
  }
}
