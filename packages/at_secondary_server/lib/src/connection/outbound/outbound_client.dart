import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/at_request_formatter.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/at_security_context_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

// Connects to an secondary and performs required handshake to be ready to run rest of the commands
/// Handshake involves running "from", "pol" verbs on the secondary
class OutboundClient {
  static final logger = AtSignLogger('OutboundClient');

  static final RegExp _dataPrefix = RegExp('^data:');
  static final RegExp _trailingPrompt = RegExp(r'\n\S+');

  final InboundConnection inboundConnection;
  final String toAtSign;
  late OutboundMessageListener messageListener;
  final OutboundConnectionFactory outboundConnectionFactory;

  String? toHost;
  String? toPort;
  OutboundSocketConnection? outboundConnection;
  bool isConnectionCreated = false;
  bool isHandShakeDone = false;
  bool handshakeRequired;
  DateTime lastUsed = DateTime.now();
  int lookupTimeoutMillis = 5 * 1000;
  int notifyTimeoutMillis = 10 * 1000;

  at_lookup.SecondaryAddressFinder secondaryAddressFinder;

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

  OutboundClient(
    this.inboundConnection,
    this.toAtSign,
    this.secondaryAddressFinder,
    this.handshakeRequired,
    this.outboundConnectionFactory,
  );

  /// Connects to an secondary and performs required handshake to be ready to run rest of the commands
  /// Handshake involves running "from", "pol" verbs on the secondary
  /// A simple connection without any handshake is created when the value for handshake is false.
  ///
  /// @param handshake is False, establishes a simple connection
  /// @returns true if the connection is successful
  /// Throws a [SecondaryNotFoundException] if secondary is url is not found for atsign
  /// Throws a [SocketException] when a socket connection to secondary cannot be established
  /// Throws a [HandShakeException] for any exception in the handshake process
  Future<bool> connect() async {
    if (isConnectionCreated) {
      logger.warning('connect called for $toAtSign but is already connected');
      logger.warning(StackTrace.current);
      return isHandShakeDone;
    }
    var result = false;
    try {
      await _createConnectionAndListener();

      await checkRemotePublicKey();

      // 3. Establish handshake if required
      if (handshakeRequired) {
        result = await _establishHandShake();
        isHandShakeDone = result;
      }
    } on Exception catch (e) {
      close();
      final msg = 'Connection failed to $toAtSign : $e';
      logger.warning(msg);
      throw ConnectionInvalidException(msg);
    }

    lastUsed = DateTime.now();
    return result;
  }

  /// Resolves [toAtSign]'s atServer address, creates the outbound connection
  /// and starts its message listener. Called by [connect], and again by
  /// [_reconnectIfInvalid] when a peer that rejected `to:` closed the
  /// connection.
  Future<void> _createConnectionAndListener() async {
    // 1. Find secondary url for the toAtSign
    String secondaryUrl = await _findSecondary(toAtSign);
    var secondaryInfo = SecondaryUtil.getSecondaryInfo(secondaryUrl);
    toHost = secondaryInfo[0];
    toPort = secondaryInfo[1];
    // 2. Create an outbound connection for the host and port
    outboundConnection = await outboundConnectionFactory
        .createOutboundConnection(toHost!, int.parse(toPort!), toAtSign);

    // Note that the outbound connection has been created successfully
    isConnectionCreated = true;
    logger.finer('Outbound connection created for $toHost $toPort $toAtSign');

    // 3. Listen to outbound message
    messageListener = OutboundMessageListener(this);
    messageListener.listen();
  }

  /// This method is called by [connect] after the connection has been established, but
  /// before the connection has been authenticated (because looking up public data on another
  /// atServer requires the connection be unauthenticated).
  /// 1. Gets the `publickey@atSign` from the remote atServer — via the
  ///    cross-server `to:` verb when [AtSecondaryConfig.toVerbOutboundEnabled]
  ///    is on (falling back to the legacy lookup if the peer rejects `to:`),
  ///    otherwise via the legacy unauthenticated lookup.
  /// 2. If got a response, calls [AtCacheManager.put]
  /// 3. If we got a KeyNotFound  from remote atServer, calls [AtCacheManager.delete]
  Future<void> checkRemotePublicKey() async {
    var remotePublicKeyName = 'publickey$toAtSign';
    var cachedPublicKeyName = 'cached:public:$remotePublicKeyName';
    late AtData atData;
    late String remoteResponse;

    // TODO Using singleton until we have won the long war on singletons and can inject the AtCacheManager
    // TODO into this object at construction time.
    AtCacheManager cacheManager =
        AtSecondaryServerImpl.getInstance().cacheManager;

    if (AtSecondaryConfig.toVerbOutboundEnabled) {
      // Try the cross-server 'to:' verb first: sent as the first verb on the
      // connection, it declares the target tenant to the peer and returns
      // both public keys in one round trip, so no separate lookup is needed.
      bool handled = await _checkRemotePublicKeyViaToVerb(
          cacheManager, cachedPublicKeyName);
      if (handled) {
        return;
      }
      // The peer did not complete the to: exchange (it may predate the verb).
      // _checkRemotePublicKeyViaToVerb has re-established the connection if
      // the peer closed it; fall through to the legacy lookup.
    }

    String doing = 'checkRemotePublicKey looking up $remotePublicKeyName';
    try {
      remoteResponse =
          (await lookUp('all:$remotePublicKeyName', handshake: false))!;
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
        remoteResponse = remoteResponse.replaceFirst(_dataPrefix, '');
      }
      doing =
          'checkRemotePublicKey parsing response from looking up $remotePublicKeyName';
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

  /// Attempts the `to:` exchange with the peer and, on success, caches the
  /// peer's public key. Returns true when the envelope was authoritative —
  /// including when it reports that the peer has no encryption public key
  /// yet, in which case the cache is left untouched exactly as the
  /// KeyNotFound branch of the legacy path does. Returns false when the
  /// caller should fall back to the legacy lookup; in that case the
  /// connection has been re-established if the peer closed it (atServers up
  /// to v3.0.28 close the connection on an unknown verb rather than replying
  /// with an error).
  Future<bool> _checkRemotePublicKeyViaToVerb(
      AtCacheManager cacheManager, String cachedPublicKeyName) async {
    String remoteResponse;
    try {
      remoteResponse = await _sendToVerb();
    } catch (e) {
      logger.info('to:$toAtSign was not accepted by the peer ($e);'
          ' falling back to the legacy lookup');
      await _reconnectIfInvalid();
      return false;
    }
    try {
      if (remoteResponse.startsWith('data:')) {
        remoteResponse = remoteResponse.replaceFirst(_dataPrefix, '');
      }
      // 'to:' returns {"publickey":..,"signing_publickey":..} where each
      // value is a {key, data, metaData} map — the same shape as a
      // lookup:all: response.
      var envelope = jsonDecode(remoteResponse) as Map;
      var publicKeyEntry = envelope['publickey'];
      if (publicKeyEntry == null) {
        // Authoritative: the peer understands to: but has not onboarded an
        // encryption public key yet.
        return true;
      }
      // Same fromJson as the legacy path, so the peer's metadata is preserved
      // in the cache rather than replaced with a default.
      // Note: Potentially the put here may be doing a lot more than just the put.
      // See AtCacheManager.put for detailed explanation.
      await cacheManager.put(
          cachedPublicKeyName, AtData().fromJson(publicKeyEntry));
      return true;
    } catch (e, st) {
      logger.severe('Caught $e processing to: envelope from $toAtSign');
      logger.severe(st);
      // The peer spoke to: but the envelope was unusable. The connection is
      // still good, so fall back to the legacy lookup rather than giving up.
      return false;
    }
  }

  /// The legacy-lookup fallback needs a usable connection; a peer that
  /// rejected `to:` may have closed the connection rather than replying with
  /// an error. Throws if the connection cannot be re-established, which fails
  /// [connect] — the correct outcome for an unreachable peer.
  Future<void> _reconnectIfInvalid() async {
    if (outboundConnection != null && !outboundConnection!.isInValid()) {
      return;
    }
    logger.info('Outbound connection to $toAtSign is not usable after the to:'
        ' attempt; reconnecting');
    await outboundConnection?.close();
    await _createConnectionAndListener();
  }

  /// Sends the cross-server `to:@toAtSign` verb and returns the peer's raw
  /// response. This is the FIRST verb on the connection (sent from
  /// [checkRemotePublicKey], which [connect] calls before the handshake), so it
  /// declares the target tenant to the peer before any `from:`.
  /// Mirrors [scan]'s raw write/read; only used when toVerbOutboundEnabled.
  Future<String> _sendToVerb() async {
    var toRequest = AtRequestFormatter.createToRequest(toAtSign);
    try {
      await outboundConnection!.write(toRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException catch (e) {
      logger.severe('$this | encountered $e');
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }
    var result =
        await messageListener.read(maxWaitMilliSeconds: lookupTimeoutMillis);
    result = result.replaceFirst(_trailingPrompt, '');
    lastUsed = DateTime.now();
    return result;
  }

  Future<String> _findSecondary(toAtSign) async {
    at_lookup.SecondaryAddress address =
        await secondaryAddressFinder.findSecondary(toAtSign);
    return address.toString();
  }

  Future<bool> _establishHandShake() async {
    if (!isConnectionCreated) {
      throw HandShakeException(
          'Handshake cannot be initiated without an outbound connection');
    }
    try {
      //1. create from request
      await outboundConnection!.write(AtRequestFormatter.createFromRequest(
          AtSecondaryServerImpl.getInstance().currentAtSign));

      //2. Receive proof
      var fromResult = await messageListener.read();
      if (fromResult == '') {
        throw HandShakeException(
            'No response received for From:$toAtSign command');
      }

      //3. Get the session ID and the pol challenge from the response
      var cookieParams = SecondaryUtil.getCookieParams(fromResult);
      var sessionIdWithAtSign = cookieParams[2];
      var challenge = cookieParams[3];

      if (productionMode) {
        var signedChallenge = SecondaryUtil.signChallenge(
            challenge, AtSecondaryServerImpl.getInstance().signingKey);
        await SecondaryUtil.saveCookie(sessionIdWithAtSign, signedChallenge,
            AtSecondaryServerImpl.getInstance().keyValueStore);
      }

      //4. Create pol request
      await outboundConnection!.write(AtRequestFormatter.createPolRequest());

      // 5. wait for handshake result - @<current_atsign>@
      var handShakeResult = await messageListener.read();
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      if (handShakeResult.startsWith('$currentAtSign@')) {
        logger.info("pol handshake complete");
        outboundConnection!.authenticated = true;
        return true;
      } else {
        logger.info(
            "pol handshake failed - handShakeResult was $handShakeResult");
        return false;
      }
    } on ConnectionInvalidException catch (e) {
      logger.severe('$this | encountered $e');
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
      throw LookupException(
          'OutboundClient.lookUp: Handshake not done, but lookUp was called with handshake: true');
    }
    if (isHandShakeDone && !handshake) {
      throw LookupException(
          'OutboundClient.lookUp: Handshake done, but lookUp was called with handshake: false');
    }
    var lookUpRequest = AtRequestFormatter.createLookUpRequest(key);
    try {
      await outboundConnection!.write(lookUpRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException catch (e) {
      logger.severe('$this | encountered $e');
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }

    // Actually read the response from the remote secondary
    String lookupResult =
        await messageListener.read(maxWaitMilliSeconds: lookupTimeoutMillis);
    lookupResult = lookupResult.replaceFirst(_trailingPrompt, '');
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
      await outboundConnection!.write(scanRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException catch (e) {
      logger.severe('$this | encountered $e');
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }
    var scanResult = await messageListener.read();
    scanResult = scanResult.replaceFirst(_trailingPrompt, '');
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
    logger.finer('plookup result of the $key: $result');
    return result;
  }

  void close() {
    if (outboundConnection != null) {
      outboundConnection!.close();
      logger.finer('Outbound connection closed');
    }
  }

  bool isInValid() {
    bool isInvalid = false;
    if (inboundConnection.isInValid()) {
      logger.finer(
          'InboundConnection from ${inboundConnection.initiatedBy} is invalid');
      isInvalid = true;
    }
    if (outboundConnection != null && outboundConnection!.isInValid()) {
      logger.finer('OutboundConnection to $toAtSign is invalid');
      isInvalid = true;
    }
    return isInvalid;
  }

  Future<String?> notify(String notifyCommandBody,
      {bool handshake = true}) async {
    if (handshake && !isHandShakeDone) {
      throw UnAuthorizedException('Handshake failed. Cannot perform a lookup');
    }
    try {
      var notificationRequest = 'notify:$notifyCommandBody\n';
      await outboundConnection!.write(notificationRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException catch (e) {
      logger.severe('$this | encountered $e');
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }
    // Setting maxWaitMilliSeconds to 30000 to wait 30 seconds for notification
    // response.
    var notifyResult =
        await messageListener.read(maxWaitMilliSeconds: notifyTimeoutMillis);
    //notifyResult = notifyResult.replaceFirst(RegExp(r'\n\S+'), '');
    lastUsed = DateTime.now();
    return notifyResult;
  }
}

abstract class OutboundConnectionFactory {
  Future<OutboundSocketConnection> createOutboundConnection(
      String host, int port, String toAtSign);
}

class DefaultOutboundConnectionFactory implements OutboundConnectionFactory {
  final AtSignLogger logger = AtSignLogger('DefaultOutboundConnectionFactory')
    ..level = 'info'; // Log stuff regardless of overall log level
  final AtSecurityContextImpl atSecurityContext = AtSecurityContextImpl();
  final SecurityContext securityContext =
      SecurityContext(withTrustedRoots: true);
  final bool clientCertificateRequired;

  DefaultOutboundConnectionFactory({required this.clientCertificateRequired}) {
    // always set the trustedCertificatePath, we need to verify the TLS
    // connection as a client
    if (File(atSecurityContext.trustedCertificatePath).existsSync()) {
      securityContext
          .setTrustedCertificates(atSecurityContext.trustedCertificatePath);
    } else if (clientCertificateRequired) {
      throw StateError(
          '${atSecurityContext.trustedCertificatePath} is required but not found');
    }

    // If we're not required to present certs, then do nothing further
    if (!clientCertificateRequired) {
      logger.info('Will not present client cert to other atServers');
      return;
    }

    // We are required to present certificates
    // If we have separate mtls certs, use them
    if (File(atSecurityContext.privateKeyPathMtls).existsSync() &&
        File(atSecurityContext.publicKeyPathMtls).existsSync()) {
      logger.info('Using MTLS cert when making outbound client connections');
      securityContext.useCertificateChain(atSecurityContext.publicKeyPathMtls);
      securityContext.usePrivateKey(atSecurityContext.privateKeyPathMtls);
    } else // otherwise, (legacy) present our server cert as a client cert
    if (File(atSecurityContext.privateKeyPath).existsSync() &&
        File(atSecurityContext.publicKeyPath).existsSync()) {
      logger.info('Using server cert when making outbound client connections');
      securityContext.useCertificateChain(atSecurityContext.publicKeyPath);
      securityContext.usePrivateKey(atSecurityContext.privateKeyPath);
    } else {
      throw StateError('SSL Certificates are required, but none were found');
    }
  }

  @override
  Future<OutboundSocketConnection> createOutboundConnection(
      String host, int port, String toAtSign) async {
    var secureSocket = await SecureSocket.connect(
      host,
      port,
      context: securityContext,
    );
    return OutboundConnectionImpl(secureSocket, toAtSign);
  }
}
