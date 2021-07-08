import 'dart:io';

import 'package:at_server_spec/at_server_spec.dart';

abstract class AtConnectionFactory<T extends AtConnection> {
  T createConnection(Socket socket, {String? sessionId});
}
