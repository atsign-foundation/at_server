import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class AtSecondaryContext extends AtServerContext {
  String host = 'localhost';
  late int port;
  bool isKeyStoreInitialized = false;

  /// This value is normally initialized with the value from
  /// [AtSecondaryConfig.inbound_max_limit]
  int inboundConnectionLimit = 200;

  /// This value is normally initialized with the value from
  /// [AtSecondaryConfig.outbound_max_limit]
  int outboundConnectionLimit = 200;

  /// This value is normally initialized with the value from
  /// [AtSecondaryConfig.inbound_idletime_millis]
  int unauthenticatedInboundIdleTimeMillis = 10 * 60 * 1000; // 10 minutes

  /// This value is normally initialized with the value from
  /// [AtSecondaryConfig.authenticated_inbound_idletime_millis]
  int authenticatedInboundIdleTimeMillis = 30 * 24 * 60 * 60 * 1000; // 30 days

  /// This value is normally initialized with the value from
  /// [AtSecondaryConfig.outbound_idletime_millis]
  int outboundIdleTimeMillis = 10 * 60 * 1000; // ten minutes

  /// Even when number of connections is close to max allowed, we don't want to
  /// close unauthenticated connections before they've had a change to send
  /// a cram or pkam request
  int unauthenticatedMinAllowableIdleTimeMillis = 5 * 1000;

  /// Even when number of connections is close to max allowed, we don't want to
  /// be overly aggressive when closing authenticated connections
  int authenticatedMinAllowableIdleTimeMillis = 60 * 1000;

  /// When the number of connections grows beyond this proportion of the max
  /// allowed number of connections, in effect we start to reduce the 'max'
  /// idle time permitted before the server starts to close existing 'idle'
  /// connections. See [InboundConnectionImpl.isInValid]
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
