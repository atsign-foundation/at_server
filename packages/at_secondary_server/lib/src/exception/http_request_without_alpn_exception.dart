/// An HTTP request on a connection taken to be speaking the atProtocol,
/// because the client did not negotiate ALPN `http/1.1`.
class HttpRequestWithoutAlpnException implements Exception {
  /// What the client is told before the connection is closed.
  static const String message = 'HTTP requests must negotiate ALPN http/1.1';

  @override
  String toString() => 'HttpRequestWithoutAlpnException: $message';
}
