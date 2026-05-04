import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_security_context_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

import 'at_secondary_config.dart';

/// Config values in this class are set to the values in AtSecondaryConfig.
/// However we allow them to be overridden here, mainly for testability reasons.
class AtSecondaryContext extends AtServerContext {
  String host = 'localhost';
  late int port;
  bool isKeyStoreInitialized = false;

  int inboundConnectionLimit = AtSecondaryConfig.inbound_max_limit;

  int outboundConnectionLimit = AtSecondaryConfig.outbound_max_limit;

  int unauthenticatedInboundIdleTimeMillis =
      AtSecondaryConfig.unauthenticated_inbound_idletime_millis;
  int unauthenticatedOutboundIdleTimeMillis =
      AtSecondaryConfig.unauthenticated_outbound_idletime_millis;

  int authenticatedInboundIdleTimeMillis =
      AtSecondaryConfig.authenticated_inbound_idletime_millis;
  int authenticatedOutboundIdleTimeMillis =
      AtSecondaryConfig.authenticated_outbound_idletime_millis;

  /// Even when number of connections is close to max allowed, we don't want to
  /// close unauthenticated connections before they've had a change to send
  /// a cram or pkam request
  int unauthenticatedMinAllowableIdleTimeMillis = 5 * 1000; // 5 seconds

  /// Even when number of connections is close to max allowed, we don't want to
  /// be overly aggressive when closing authenticated connections
  int authenticatedMinAllowableIdleTimeMillis = 300 * 1000; // 5 minutes

  /// When the number of connections grows beyond this proportion of the max
  /// allowed number of connections, in effect we start to reduce the 'max'
  /// idle time permitted before the server starts to close existing 'idle'
  /// connections. See [InboundConnectionImpl.isInValid]
  double inboundConnectionLowWaterMarkRatio = 0.8;
  bool progressivelyReduceAllowableInboundIdleTime = true;

  String? currentAtSign;
  String? sharedSecret;
  AtSecurityContextImpl? securityContext;
  SecondaryKeyStore? secondaryKeyStore;
  VerbExecutor? verbExecutor;

  // When true, SecondaryServerImpl will gracefully shut down the service immediately
  // after fully starting up.
  bool trainingMode = false;
}
