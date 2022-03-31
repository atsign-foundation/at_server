import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
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

// Connects to an secondary and performs required handshake to be ready to run rest of the commands
/// Handshake involves running "from", "pol" verbs on the secondary
class OutboundClient {
  var logger = AtSignLogger('OutboundClient');
  static final _rootDomain = AtSecondaryConfig.rootServerUrl;
  static final _rootPort = AtSecondaryConfig.rootServerPort;
  InboundConnection inboundConnection;

  OutboundConnection? outboundConnection;

  String? toAtSign;
  String? toHost;
  String? toPort;

  bool isConnectionCreated = false;

  bool isHandShakeDone = false;

  late OutboundMessageListener messageListener;

  OutboundClient(this.inboundConnection, this.toAtSign);

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
    var result = false;
    try {
      // 1. Find secondary url for the toAtSign
      var secondaryUrl = await _findSecondary(toAtSign);
      var secondaryInfo = SecondaryUtil.getSecondaryInfo(secondaryUrl);
      toHost = secondaryInfo[0];
      toPort = secondaryInfo[1];
      // 2. Create an outbound connection for the host and port
      var connectResult = await _createOutBoundConnection(toHost, toPort, toAtSign);
      if (connectResult) {
        isConnectionCreated = true;
      }

      // 3. Listen to outbound message
      messageListener = OutboundMessageListener(this);
      messageListener.listen();
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
      logger.severe('HandShakeException for $toAtSign: ${e.toString()}');
      rethrow;
    }
    return result;
  }

  Future<String> _findSecondary(toAtSign) async {
    var secondaryUrl = await at_lookup.AtLookupImpl.findSecondary(
        toAtSign, _rootDomain, _rootPort!);
    if (secondaryUrl == null) {
      throw SecondaryNotFoundException(
          'No secondary url found for atsign: $toAtSign');
    }
    return secondaryUrl;
  }

  Future<bool> _createOutBoundConnection(host, port, toAtSign) async {
    try {
      var securityContext = AtSecurityContextImpl();
      var secConConnect = SecurityContext();
      secConConnect.useCertificateChain(securityContext.publicKeyPath());
      secConConnect.usePrivateKey(securityContext.privateKeyPath());
      secConConnect
          .setTrustedCertificates(securityContext.trustedCertificatePath());
      var secureSocket = await SecureSocket.connect(host, int.parse(port),
          context: secConConnect);
      outboundConnection = OutboundConnectionImpl(secureSocket, toAtSign);
    } on SocketException {
      throw SecondaryNotFoundException('unable to connect to secondary');
    }
    return true;
  }

  Future<bool> _establishHandShake() async {
    var result = false;
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
      logger.info('fromResult : $fromResult');
      if (fromResult == null || fromResult == '') {
        throw HandShakeException(
            'no response received for From:$toAtSign command');
      }

      //3. Save cookie
      var cookieParams = SecondaryUtil.getCookieParams(fromResult);
      var sessionIdWithAtSign = cookieParams[2];
      var proof = cookieParams[3];
      var signedChallenge = SecondaryUtil.signChallenge(
          proof, AtSecondaryServerImpl.getInstance().signingKey);
      await SecondaryUtil.saveCookie(sessionIdWithAtSign, signedChallenge,
          AtSecondaryServerImpl.getInstance().currentAtSign);

      //4. Create pol request
      outboundConnection!.write(AtRequestFormatter.createPolRequest());

      // 5. wait for handshake result - @<current_atsign>@
      var handShakeResult = await messageListener.read();
      logger.finer('handShakeResult: $handShakeResult');
      if (handShakeResult == null) {
        await outboundConnection!.close();
        throw HandShakeException('no response received for pol command');
      }
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      if (handShakeResult.startsWith('$currentAtSign@')) {
        result = true;
      }
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    } on Exception catch (e) {
      await outboundConnection!.close();
      throw HandShakeException(e.toString());
    }
    return result;
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
    if (handshake && !isHandShakeDone) {
      throw UnAuthorizedException(
          'Handshake did not succeed. Cannot perform a lookup');
    }
    var lookUpRequest = AtRequestFormatter.createLookUpRequest(key);
    try {
      logger.finer('writing to outbound connection: $lookUpRequest');
      outboundConnection!.write(lookUpRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }

    // Actually read the response from the remote secondary
    var lookupResult = await messageListener.read();

    if (lookupResult != null) {
      lookupResult = lookupResult.replaceFirst(RegExp(r'\n\S+'), '');
    }
    logger.finer('lookup result after format: $lookupResult');
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
      logger.finer('writing to outbound connection: $scanRequest');
      outboundConnection!.write(scanRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }
    var scanResult = await messageListener.read();
    if (scanResult != null) {
      scanResult = scanResult.replaceFirst(RegExp(r'\n\S+'), '');
    }
    logger.finer('scan result after format: $scanResult');
    return scanResult;
  }

  /// Runs a "plookup" on the secondary of the @sign that this instance represents.
  ///
  /// @param key - key to be looked up
  /// @returns result of the plookup returned by the secondary
  /// Throws a [LookupException] if there is exception during lookup
  Future<String?> plookUp(String key) async {
    var result = await lookUp(key, handshake: false);
    return result;
  }

  void close() {
    if (outboundConnection != null) {
      outboundConnection!.close();
    }
  }

  bool isInValid() {
    if (outboundConnection != null && outboundConnection!.isInValid()) {
      return true;
    }

    // TODO This is weird. Why are we checking if the inbound connection is inValid?
    if (inboundConnection.isInValid()) {
      if (inboundConnection is DummyInboundConnection) {
        return false;
      } else {
        logger.warning('isInValid() found that its associated inbound connection (sessionID: ${inboundConnection
            .getMetaData()
            .sessionID}) is inValid - this *outbound* client is therefore being marked as inValid');
        return true;
      }
    } else {
      return false;
    }
  }

  Future<String?> notify(String key, {bool handshake = true}) async {
    if (handshake && !isHandShakeDone) {
      throw UnAuthorizedException(
          'Handshake did not succeed. Cannot perform a lookup');
    }
    try {
      var notificationRequest = 'notify:$key\n';
      logger.info('notificationRequest : $notificationRequest');
      outboundConnection!.write(notificationRequest);
    } on AtIOException catch (e) {
      await outboundConnection!.close();
      throw LookupException(
          'Exception writing to outbound socket ${e.toString()}');
    } on ConnectionInvalidException {
      throw OutBoundConnectionInvalidException('Outbound connection invalid');
    }
    logger.info('waiting for response from outbound connection');
    // Setting maxWaitMilliSeconds to 30000 to wait 30 seconds for notification
    // response.
    var notifyResult = await messageListener.read(maxWaitMilliSeconds: 30000);
    //notifyResult = notifyResult.replaceFirst(RegExp(r'\n\S+'), '');
    logger.info('notifyResult result after format: $notifyResult');
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

    return notifyResult.sentNotifications;
  }
}
