import 'dart:io';

import 'package:at_commons/at_commons.dart';

abstract class AtConnectionFactory<T extends AtConnection> {
  T createConnection(Socket socket, {String? sessionId});
}
