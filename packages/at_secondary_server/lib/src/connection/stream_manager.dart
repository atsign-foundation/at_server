import 'package:at_server_spec/at_server_spec.dart';

/// Registry of active stream sender/receiver sockets, keyed by streamId.
///
/// Owned by `AtSecondaryServerImpl` and injected via `VerbHandlerContext`;
/// formerly a singleton holding two static maps.
class StreamManager {
  StreamManager();

  final Map<String, InboundConnection> senderSocketMap = {};

  final Map<String, InboundConnection> receiverSocketMap = {};
}
