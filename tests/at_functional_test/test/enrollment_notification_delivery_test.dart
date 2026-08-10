import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional coverage of the notification authorization gate
/// ([MonitorVerbHandler._sendNotification]): a monitor belonging to a scoped
/// enrollment is delivered notifications for the namespaces that enrollment
/// holds, and not for the ones it does not.
///
/// A monitor is read over a RAW socket rather than [OutboundConnectionFactory].
/// That wrapper's listener only surfaces responses beginning `data:`,
/// `stream:`, `error:` or `@...@` (`OutboundMessageListener._isValidResponse`),
/// and a monitor frame begins `notification:` — so the wrapper structurally
/// cannot read one, and a test built on it reports a delivery that did happen
/// as a timeout.
void main() {
  String atSign = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String host = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int port = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String apkamPublicKey = apkamPublicKeyMap[atSign]!;
  String encryptedPrivateKey = EncryptionUtil.encryptValue(
      encryptionPrivateKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedSelfKey = EncryptionUtil.encryptValue(
      aesKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedApkamSymmetricKey = EncryptionUtil.encryptKey(
      apkamSymmetricKeyMap[atSign]!, encryptionPublicKeyMap[atSign]!);

  List<OutboundConnectionFactory> open = [];

  Future<OutboundConnectionFactory> newConnection() async {
    OutboundConnectionFactory c = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    open.add(c);
    return c;
  }

  tearDown(() async {
    for (final c in open) {
      await c.close();
    }
    open = [];
  });

  /// Opens a monitor APKAM-authenticated as [enrollmentId], replaying the
  /// backlog from [since], and returns everything the server wrote.
  ///
  /// Chunks are accumulated and matched against the whole buffer: the '@'
  /// prompt and the `from:` challenge can arrive coalesced in one read, so a
  /// `startsWith` on an individual chunk misses them.
  Future<String> monitorAs(String enrollmentId, int since) async {
    StringBuffer buffer = StringBuffer();
    SecureSocket socket = await SecureSocket.connect(host, port);
    bool pkamSent = false;
    bool monitorSent = false;

    socket.listen((data) {
      buffer.write(utf8.decode(data));
      String all = buffer.toString();
      if (!pkamSent && all.contains('data:_')) {
        pkamSent = true;
        int start = all.indexOf('data:_') + 'data:'.length;
        int end = all.indexOf('\n', start);
        String challenge =
            all.substring(start, end == -1 ? all.length : end).trim();
        String digest = AuthenticationUtils.generatePKAMDigest(
            apkamPrivateKeyMap[atSign]!, challenge);
        socket.write('pkam:enrollmentId:$enrollmentId:$digest\n');
      } else if (pkamSent && !monitorSent && all.contains('data:success')) {
        monitorSent = true;
        socket.write('monitor:selfNotifications:$since\n');
      }
    });

    socket.write('from:$atSign\n');
    // The backlog is served immediately on the monitor command; this window is
    // for the server to work through it, not for anything to be produced.
    await Future.delayed(Duration(seconds: 8));
    await socket.close();
    return buffer.toString();
  }

  test('a scoped enrollment\'s monitor is given its own namespace and not another',
      () async {
    OutboundConnectionFactory owner = await newConnection();
    expect((await owner.authenticateConnection(authType: AuthType.cram)).trim(),
        'data:success');

    // An enrollment scoped to `wavi` only.
    String otp = (await owner.sendRequestToServer('otp:get'))
        .replaceFirst('data:', '')
        .trim();
    OutboundConnectionFactory requester = await newConnection();
    String enrollResponse = await requester.sendRequestToServer(
        'enroll:request:{"appName":"notify-app-${Uuid().v4().hashCode}","deviceName":"device-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"$apkamPublicKey","encryptedAPKAMSymmetricKey":"$encryptedApkamSymmetricKey"}');
    String enrollmentId =
        jsonDecode(enrollResponse.replaceFirst('data:', ''))['enrollmentId'];
    String approval = await owner.sendRequestToServer(
        'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"$encryptedPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfKey"}');
    expect(jsonDecode(approval.replaceFirst('data:', ''))['status'], 'approved');

    // Both notifications are created BEFORE the monitor connects and are
    // replayed from a timestamp, so this does not race the monitor's socket
    // becoming ready. @alice -> @alice, so both are typed `received`, which is
    // what the monitor backlog serves.
    int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    String unique = Uuid().v4().hashCode.toString();
    String grantedKey = 'granted-$unique.wavi';
    String ungrantedKey = 'ungranted-$unique.buzz';

    expect(
        (await owner.sendRequestToServer(
                'notify:update:ttr:-1:$atSign:$grantedKey$atSign:granted-value'))
            .trim(),
        startsWith('data:'));
    expect(
        (await owner.sendRequestToServer(
                'notify:update:ttr:-1:$atSign:$ungrantedKey$atSign:ungranted-value'))
            .trim(),
        startsWith('data:'));

    String delivered = await monitorAs(enrollmentId, since);

    // Establish the monitor got as far as being a monitor at all, so the
    // absence asserted below is a refusal and not a broken connection.
    expect(delivered, contains('data:success'),
        reason: 'the monitor must have APKAM-authenticated as the enrollment');

    // The positive arm is what makes the negative arm meaningful: the monitor
    // demonstrably reached this point of the backlog.
    expect(delivered, contains(grantedKey),
        reason: 'a notification in the enrollment\'s own namespace must reach '
            'its monitor');
    expect(delivered, isNot(contains(ungrantedKey)),
        reason: 'a notification outside the granted namespace must not reach '
            'it — and a drop must not be indistinguishable from a send that '
            'never happened');
  }, timeout: Timeout(Duration(minutes: 3)));
}
