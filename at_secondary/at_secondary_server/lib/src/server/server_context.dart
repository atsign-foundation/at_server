import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class AtSecondaryContext extends AtServerContext {
  String host = 'localhost';
  late int port;
  bool isKeyStoreInitialized = false;
  int? inboundConnectionLimit = 10;
  int? outboundConnectionLimit = 10;
  int? inboundIdleTimeMillis = 600000;
  int? outboundIdleTimeMillis = 600000;

  // Setting to empty string. AtSign will be set on server start-up.
  String currentAtSign = '';
  String? sharedSecret;
  AtSecurityContext? securityContext;
  SecondaryKeyStore? secondaryKeyStore;
  VerbExecutor? verbExecutor;
}
