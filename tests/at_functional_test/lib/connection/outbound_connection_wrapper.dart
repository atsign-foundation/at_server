import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_lookup/src/connection/outbound_message_listener.dart';
import 'package:at_utils/at_logger.dart';

class OutboundConnectionFactory {
  final logger = AtSignLogger('OutboundConnectionFactory');

  late OutboundConnection _outboundConnection;

  late OutboundMessageListener _outboundMessageListener;

  late String atSign;

  Future<OutboundConnectionFactory> initiateConnectionWithListener(
      String atSign, String host, int port) async {
    SecureSocket secureSocket = await SecureSocket.connect(host, port);
    _outboundConnection = OutboundConnectionImpl(secureSocket);
    _outboundMessageListener = OutboundMessageListener(_outboundConnection);
    _outboundMessageListener.listen();
    this.atSign = atSign;
    return this;
  }

  Future<String> sendRequestToServer(String message,
      {int maxWaitMilliSeconds = 90000}) async {
    if (!(message.endsWith('\n'))) {
      message = message + '\n';
    }
    await _outboundConnection.write(message);
    return await getServerResponse(maxWaitMilliSeconds: maxWaitMilliSeconds);
  }

  Future<String> getServerResponse({int maxWaitMilliSeconds = 90000}) async {
    return await _outboundMessageListener.read(
        maxWaitMilliSeconds: maxWaitMilliSeconds);
  }

  Future<String> authenticateConnection(
      {AuthType authType = AuthType.pkam, String enrollmentId = ''}) async {
    switch (authType) {
      case AuthType.pkam:
        return await _pkamAuthentication(enrollmentId: enrollmentId);
      case AuthType.cram:
        return await _cramAuthentication();
      case AuthType.apkam:
        return await _apkamAuthentication(enrollmentId);
      default:
        return await _pkamAuthentication();
    }
  }

  Future<String> _pkamAuthentication({String enrollmentId = ''}) async {
    await _outboundConnection.write(
        'from:$atSign:clientConfig:${jsonEncode({'version': '3.0.57'})}\n');
    String fromResponse = await _outboundMessageListener.read();
    fromResponse = fromResponse.replaceAll('data:', '');
    String pkamDigest = AuthenticationUtils.generatePKAMDigest(
        pkamPrivateKeyMap[atSign]!, fromResponse);
    String pkamCommand = 'pkam:';
    if (enrollmentId.isNotEmpty) {
      pkamCommand += 'enrollmentId:$enrollmentId:';
    }
    pkamCommand += '$pkamDigest\n';
    await _outboundConnection.write(pkamCommand);
    String pkamResponse = await _outboundMessageListener.read();
    if (pkamResponse == 'data:success') {
      logger.finer('Connection authentication via PKAM is successful');
    } else {
      logger.finer('Connection authentication via PKAM has failed');
    }
    return pkamResponse;
  }

  Future<String> _apkamAuthentication(String enrollmentId) async {
    if (enrollmentId.isEmpty) {
      throw UnAuthenticatedException('Enrollment Id cannot be empty');
    }
    await _outboundConnection.write(
        'from:$atSign:clientConfig:${jsonEncode({'version': '3.0.57'})}\n');
    String fromResponse = await _outboundMessageListener.read();
    fromResponse = fromResponse.replaceAll('data:', '');
    String pkamDigest = AuthenticationUtils.generatePKAMDigest(
        apkamPrivateKeyMap[atSign]!, fromResponse);
    await _outboundConnection
        .write('pkam:enrollmentId:$enrollmentId:$pkamDigest\n');
    String pkamResponse = await _outboundMessageListener.read();
    if (pkamResponse == 'data:success') {
      logger.finer('Connection authentication via APKAM is successful');
    } else {
      logger.finer('Connection authentication via APKAM has failed');
    }
    return pkamResponse;
  }

  Future<String> _cramAuthentication() async {
    await _outboundConnection.write(
        'from:$atSign:clientConfig:${jsonEncode({'version': '3.0.57'})}\n');
    String fromResponse = await _outboundMessageListener.read();
    fromResponse = fromResponse.replaceAll('data:', '');
    String pkamDigest = AuthenticationUtils.getCRAMDigest(atSign, fromResponse);
    await _outboundConnection.write('cram:$pkamDigest\n');
    String cramResponse = await _outboundMessageListener.read();
    if (cramResponse == 'data:success') {
      logger.finer('Connection authentication via CRAM is successful');
    } else {
      logger.finer('Connection authentication via CRAM has failed');
    }
    return cramResponse;
  }

  Future<void> close() async {
    await _outboundConnection.close();
  }
}

enum AuthType { pkam, cram, apkam }
