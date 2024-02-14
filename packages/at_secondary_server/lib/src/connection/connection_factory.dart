import 'dart:io';

import 'package:at_server_spec/at_server_spec.dart';

abstract class AtConnectionFactory<T extends AtConnection> {
  T createSocketConnection(Socket socket, {String? sessionId});
}
