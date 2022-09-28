import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class AtSecondaryContext extends AtServerContext {
  String host = 'localhost';
  late int port;
  bool isKeyStoreInitialized = false;
  int inboundConnectionLimit = 50;
  int outboundConnectionLimit = 50;
  int inboundIdleTimeMillis = 600000;
  int outboundIdleTimeMillis = 600000;

  int unauthenticatedMinAllowableIdleTimeMillis = 5000; // have to allow time for connection handshakes // TODO Run tests to identify a p99.999 value
  double inboundConnectionLowWaterMarkRatio = 0.5;
  bool progressivelyReduceAllowableInboundIdleTime = true;
  String? currentAtSign;
  String? sharedSecret;
  AtSecurityContext? securityContext;
  SecondaryKeyStore? secondaryKeyStore;
  VerbExecutor? verbExecutor;
  // When true, SecondaryServerImpl will gracefully shut down the service immediately
  // after fully starting up.
  bool trainingMode = false;
}
