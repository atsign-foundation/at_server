import 'dart:convert';

import 'package:test/test.dart';
// ignore: depend_on_referenced_packages
import 'package:uuid/uuid.dart';

import 'e2e_test_utils.dart' as e2e;
import 'notify_verb_test.dart' as notification;

/// Does `notify:multi` deliver one value, with the metadata a recipient
/// needs to read it, to every recipient?
///
/// @first sends one `notify:multi` to @second and to itself. @second's copy
/// crosses to @second's own atServer as a plain notify; @first's stays on
/// @first's atServer. Both must carry the value, `isEncrypted` and
/// `appMetadata`.
void main() {
  late String atSign_1;
  late e2e.SimpleOutboundConnection sh1;

  late String atSign_2;
  late e2e.SimpleOutboundConnection sh2;

  final appMetadataJson = {
    'providerId': 'at/symmetric/AES/GCM/multirecipient',
    'ckKid': 'k-e2e',
    'iv': 'aXY=',
  };
  final encodedAppMetadata =
      base64Encode(utf8.encode(jsonEncode(appMetadataJson)));

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();
    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() async {
    sh1.clear();
    sh2.clear();
  });

  /// Whether [sh]'s atServer lists the feature [name] in its `info`.
  Future<bool> listsFeature(
      e2e.SimpleOutboundConnection sh, String name) async {
    await sh.writeCommand('info');
    final info = jsonDecode((await sh.read()).replaceFirst('data:', ''));
    final List features = info['features'] ?? [];
    return features.any((f) => f['name'] == name);
  }

  /// The notification [sh] lists for [notificationKey], polling until it
  /// arrives.
  Future<Map> listed(e2e.SimpleOutboundConnection sh, String regex,
      String notificationKey) async {
    final response = await notification.retryCommandUntilMatchOrTimeout(
        sh, 'notify:list:$regex', '"key":"$notificationKey"', 15000);
    final List entries = jsonDecode(response.replaceFirst('data:', ''));
    return entries.singleWhere((n) => n['key'] == notificationKey);
  }

  test('notify:multi delivers the value and its metadata to every recipient',
      () async {
    // This pack also runs against long-lived atSigns whose atServers may
    // predate notify:multi; a client checks info the same way.
    if (!await listsFeature(sh1, 'notify.multi')) {
      print('$atSign_1\'s atServer does not list notify.multi. Skipping.');
      return;
    }

    final key = 'multi-${Uuid().v4()}';
    final value = 'CIPHERTEXT-${Uuid().v4()}';
    await sh1.writeCommand('notify:multi:update:isEncrypted:true'
        ':appMetadata:$encodedAppMetadata'
        ':$atSign_2,$atSign_1:$key.e2e$atSign_1:$value');
    final Map reply = jsonDecode((await sh1.read()).replaceFirst('data:', ''));
    expect(reply.keys.toSet(), {atSign_2, atSign_1},
        reason: 'the reply names every recipient');

    final status = await notification.getNotifyStatus(sh1, reply[atSign_2],
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    expect(status, contains('data:delivered'));

    final recipients = {atSign_2: sh2, atSign_1: sh1};
    for (final recipient in recipients.keys) {
      final n = await listed(
          recipients[recipient]!, key, '$recipient:$key.e2e$atSign_1');
      expect(n['value'], value);
      expect(n['isEncrypted'], isTrue);
      expect(n['metadata']['appMetadata'], appMetadataJson,
          reason: '$recipient needs the provider, key id and iv to decrypt');
    }
  });
}
