import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/at_request_formatter.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/at_security_context_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

// Connects to an secondary and performs required handshake to be ready to run rest of the commands
/// Handshake involves running "from", "pol" verbs on the secondary
class OutboundClient {
  var logger = AtSignLogger('OutboundClient');
  static final _rootDomain = AtSecondaryConfig.rootServerUrl;
  static final _rootPort = AtSecondaryConfig.rootServerPort;

  final InboundConnection inboundConnection;
  final String toAtSign;

  String? toHost;
  String? toPort;
  OutboundConnection? outboundConnection;
  bool isConnectionCreated = false;
  bool isHandShakeDone = false;
  DateTime lastUsed = DateTime.now();
  int lookupTimeoutMillis = 5 * 1000;
  int notifyTimeoutMillis = 10 * 1000;

  at_lookup.SecondaryAddressFinder? secondaryAddressFinder;

  /// When unit testing, we don't need to do all the things necessary
  /// to support server-to-server handshake - for example, actually signing
  /// a pol challenge, nor creating a key which stores that signature.
  @visibleForTesting
  bool productionMode = true;

  @override
  String toString() {
    return 'OutboundClient{toAtSign: $toAtSign, toHost: $toHost, toPort: $toPort, '
        'isConnectionCreated: $isConnectionCreated, isHandShakeDone: $isHandShakeDone}';
  }

  late OutboundMessageListener messageListener;

  late OutboundConnectionFactory _outboundConnectionFactory;

  OutboundClient(this.inboundConnection, this.toAtSign,
      {this.secondaryAddressFinder, OutboundConnectionFactory? outboundConnectionFactory}) {
    outboundConnectionFactory ??= DefaultOutboundConnectionFactory();
    _outboundConnectionFactory = outboundConnectionFactory;
  }

  /// Connects to an secondary and performs required handshake to be ready to run rest of the commands
  /// Handshake involves running "from", "pol" verbs on the secondary
  /// A simple connection without any handshake is created when the value for handshake is false.
  ///
  /// @param handshake is False, establishes a simple connection
  /// @returns true if the connection is successful
  /// Throws a [SecondaryNotFoundException] if secondary is url is not found for atsign
  /// Throws a [SocketException] when a socket connection to secondary cannot be established
  /// Throws a [HandShakeException] for any exception in the handshake process
  Future<bool> connect({bool handshake = true}) async {
    logger.finer('connect(handshake:$handshake) called for $toAtSign');
    var result = false;
    try {
      // 1. Find secondary url for the toAtSign
      var secondaryUrl = await _findSecondary(toAtSign);
      var secondaryInfo = SecondaryUtil.getSecondaryInfo(secondaryUrl);
      String toHost = secondaryInfo[0];
      int toPort = int.parse(secondaryInfo[1]);
      // 2. Create an outbound connection for the host and port
      outboundConnection = await _outboundConnectionFactory.createOutboundConnection(toHost, toPort, toAtSign);
      isConnectionCreated = true;

      // 3. Listen to outbound message
      messageListener = OutboundMessageListener(this);
      messageListener.listen();

      await checkRemotePublicKey();

      // 3. Establish handshake if required
      if (handshake) {
        result = await _establishHandShake();
        isHandShakeDone = result;
      }
    } on SecondaryNotFoundException catch (e) {
      logger
          .severe('secondary server not found for $toAtSign: ${e.toString()}');
      rethrow;
    } on SocketException catch (e) {
      logger.severe(
          'socket exception connecting to secondary $toAtSign: ${e.toString()}');
      rethrow;
    } on HandShakeException catch (e) {
      logger.severe('HandShakeException connecting to secondary $toAtSign: ${e.toString()}');
      rethrow;
    }

    lastUsed = DateTime.now();
    return result;
  }

  /// This method is called by [connect] after the connection has been established, but
  /// before the connection has been authenticated (because looking up public data on another
  /// atServer requires the connection be unauthenticated).
  /// 1. Gets the `publickey@atSign` from the remote atServer
  /// 2. If got a response, calls [AtCacheManager.put]
  /// 3. If we got a KeyNotFound  from remote atServer, calls [AtCacheManager.delete]
  Future<void> checkRemotePublicKey() async {
    var remotePublicKeyName = 'publickey$toAtSign';
    var cachedPublicKeyName = 'cached:public:$remotePublicKeyName';
    late AtData atData;
    late String remoteResponse;

    // TODO Using singleton until we have won the long war on singletons and can inject the AtCacheManager
    // TODO into this object at construction time.
    AtCacheManager cacheManager = AtSecondaryServerImpl.getInstance().cacheManager;

    String doing = 'checkRemotePublicKey looking up $remotePublicKeyName';
    try {
      remoteResponse = (await lookUp('all:$remotePublicKeyName', handshake: false))!;
    } on KeyNotFoundException {
      // Do nothing
      return;
    } catch (e, st) {
      logger.severe('Caught $e while $doing');
      logger.severe(st);
      return;
    }

    doing = 'checkRemotePublicKey removing "data:" from the response';
    try {
      if (remoteResponse.startsWith('data:')) {
        remoteResponse = remoteResponse.replaceFirst('data:', '');
      }
      doing = 'checkRemotePublicKey parsing response from looking up $remotePublicKeyName';
      atData = AtData().fromJson(jsonDecode(remoteResponse));

      doing = 'checkRemotePublicKey updating $cachedPublicKeyName in cache';
      // Note: Potentially the put here may be doing a lot more than just the put.
      // See AtCacheManager.put for detailed explanation.
      await cacheManager.put(cachedPublicKeyName, atData);
    } catch (e, st) {
      logger.severe('Caught $e while $doing');
      logger.severe(st);
      return;
    }
  }

  Future<String> _findSecondary(toAtSign) async {
    if (secondaryAddressFinder != null) {
      at_lookup.SecondaryAddress address = await secondaryAddressFinder!.findSecondary(toAtSign);
      return address.toString();
    }

    // ignore: deprecated_member_use
    var secondaryUrl = await at_lookup.AtLookupImpl.findSecondary(
        toAtSign, _rootDomain, _rootPort!);
    if (secondaryUrl == null) {
      throw SecondaryNotFoundException(
          'No secondary url found for atsign: $toAtSign');
    }
    return secondaryUrl;
  }

  Future<bool> _establishHandShake() async {
    if (!isConnectionCreated) {
      throw HandShakeException(
          'Handshake cannot be initiated without an outbound connection');
    }
    try {
      //1. create from request
      outboundConnection!.write(AtRequestFormatter.createFromRequest(
          AtSecondaryServerImpl.getInstance().currentAtSign));

      //2. Receive proof
      var fromResult = await messageListener.read();
      if (fromResult == '') {
        throw HandShakeException(
            'no response received for From:$toAtSign command');
      }

      //3. Get the session ID and the pol challenge from the response
      var cookieParams = SecondaryUtil.getCookieParams(fromResult);
      var sessionIdWithAtSign = cookieParams[2];
      var challenge = cookieParams[3];

      if (productionMode) {
        var signedChallenge = SecondaryUtil.signChallenge(
            challenge, AtSecondaryServerImpl
            .getInstance()
            .signingKey);
        await SecondaryUtil.saveCookie(sessionIdWithAtSign, signedChallenge,
            AtSecondaryServerImpl
                .getInstance()
                .currentAtSign);
      }

      //4. Create pol request
      outboundConnection!.write(AtRequestFormatter.createPolRequest());

      // 5. wait for handshake result - @<current_atsign>@
      var handShakeResult = await messageListener.read();
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      if (handShakeResult.startsWith('$currentAtSign@')) {
        logger.info("pol handshake complete");
        return true;
      } else {
        logger.info("pol handshake failed - handShakeResult was $handShakeResult");
        return false;
      }
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    } catch (e) {
      await outboundConnection!.close();
      throw HandShakeException(e.toString());
    }
  }

  /// Runs "lookup" verb on the secondary of the @sign that this instance represents.
  ///
  /// @param key - Key to be looked up
  /// @param auth - True if the lookup needs to run on an authenticated connection
  /// @returns String Result of the "lookup" verb returned by the secondary
  /// Throws a [UnAuthorizedException] if lookup if invoked with handshake=true and without a successful handshake
  /// Throws a [LookupException] if there is exception during lookup
  /// Throws a [OutBoundConnectionInvalidException] if we are trying to write to an invalid connection
  Future<String?> lookUp(String key, {bool handshake = true}) async {
    logger.finer('lookUp($key, handshake:$handshake) called for $toAtSign');
    if (handshake && !isHandShakeDone) {
      throw LookupException('OutboundClient.lookUp: Handshake not done, but lookUp was called with handshake: true');
    }
    if (isHandShakeDone && !handshake) {
      throw LookupException('OutboundClient.lookUp: Handshake done, but lookUp was called with handshake: false');
    }
    var lookUpRequest = AtRequestFormatter.createLookUpRequest(key);
    try {
      outboundConnection!.write(lookUpRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }

    // Actually read the response from the remote secondary
    String lookupResult = await messageListener.read(maxWaitMilliSeconds: lookupTimeoutMillis);
    lookupResult = lookupResult.replaceFirst(RegExp(r'\n\S+'), '');
    lastUsed = DateTime.now();
    return lookupResult;
  }

  Future<String?> scan({bool handshake = true, String? regex}) async {
    if (handshake && !isHandShakeDone) {
      throw UnAuthorizedException(
          'Handshake did not succeed. Cannot perform a outbound scan');
    }
    var scanRequest = 'scan\n';
    //Adding regular expression to the scan verb
    if (regex != null && regex != '') {
      scanRequest = 'scan $regex\n';
    }
    try {
      outboundConnection!.write(scanRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }
    var scanResult = await messageListener.read();
    scanResult = scanResult.replaceFirst(RegExp(r'\n\S+'), '');
    lastUsed = DateTime.now();
    return scanResult;
  }

  /// Runs a "plookup" on the secondary of the @sign that this instance represents.
  ///
  /// @param key - key to be looked up
  /// @returns result of the plookup returned by the secondary
  /// Throws a [LookupException] if there is exception during lookup
  Future<String?> plookUp(String key) async {
    var result = await lookUp(key, handshake: false);
    lastUsed = DateTime.now();
    return result;
  }

  void close() {
    if (outboundConnection != null) {
      outboundConnection!.close();
    }
  }

  bool isInValid() {
    return inboundConnection.isInValid() ||
        (outboundConnection != null && outboundConnection!.isInValid());
  }

  Future<String?> notify(String notifyCommandBody, {bool handshake = true}) async {
    if (handshake && !isHandShakeDone) {
      throw UnAuthorizedException(
          'Handshake did not succeed. Cannot perform a lookup');
    }
    try {
      var notificationRequest = 'notify:$notifyCommandBody\n';
      outboundConnection!.write(notificationRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }
    // Setting maxWaitMilliSeconds to 30000 to wait 30 seconds for notification
    // response.
    var notifyResult = await messageListener.read(maxWaitMilliSeconds: notifyTimeoutMillis);
    //notifyResult = notifyResult.replaceFirst(RegExp(r'\n\S+'), '');
    lastUsed = DateTime.now();
    return notifyResult;
  }

  Future<List>? notifyList(String? atSign, {bool handshake = true}) async {
    // ignore: prefer_typing_uninitialized_variables
    var notifyResult;
    if (handshake && !isHandShakeDone) {
      throw UnAuthorizedException(
          'Handshake did not succeed. Cannot perform a lookup');
    }
    try {
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      notifyResult = await notificationKeyStore.getValues();
      if (notifyResult != null) {
        notifyResult.retainWhere((element) =>
            element.type == NotificationType.sent &&
            atSign == element.toAtSign);
      }
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }

    lastUsed = DateTime.now();
    return notifyResult.sentNotifications;
  }
}

abstract class OutboundConnectionFactory {
  Future<OutboundConnection> createOutboundConnection(String host, int port, String toAtSign);
}

class DefaultOutboundConnectionFactory implements OutboundConnectionFactory {
  @override
  Future<OutboundConnection> createOutboundConnection(String host, int port, String toAtSign) async {
    var securityContext = AtSecurityContextImpl();
    var secConConnect = SecurityContext();
    secConConnect.useCertificateChain(securityContext.publicKeyPath());
    secConConnect.usePrivateKey(securityContext.privateKeyPath());
    secConConnect.setTrustedCertificates(securityContext.trustedCertificatePath());
    var secureSocket = await SecureSocket.connect(host, port, context: secConConnect);
    return OutboundConnectionImpl(secureSocket, toAtSign);
  }
}
