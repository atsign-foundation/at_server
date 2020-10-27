import 'package:at_server_spec/at_server_spec.dart';

class StreamManager {
  static final StreamManager _singleton = StreamManager._internal();
  factory StreamManager() {
    return _singleton;
  }

  StreamManager._internal();

  static Map<String, InboundConnection> senderSocketMap = {};

  static Map<String, InboundConnection> receiverSocketMap = {};
}
