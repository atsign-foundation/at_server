import 'dart:convert';

import 'package:test/test.dart';
// ignore: depend_on_referenced_packages
import 'package:uuid/uuid.dart';
import 'package:version/version.dart';

import 'e2e_test_utils.dart' as e2e;

/// Does `appMetadata` survive a CROSS-atSign `lookup:all`?
///
/// The functional pack covers the same-server paths — an llookup round trip
/// and sync. This drives the remote one: @first shares a key carrying
/// appMetadata with @second, and @second looks it up through its OWN server,
/// which pol-authenticates to @first's server and relays the response.
void main() {
  late String atSign_1;
  late e2e.SimpleOutboundConnection sh1;

  late String atSign_2;
  late e2e.SimpleOutboundConnection sh2;

  final appMetadataJson = {
    'providerId': 'acme_provider',
    'keyId': 'k-123',
    'mode': 'hpke',
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
    print("Clearing socket response queues");
    sh1.clear();
    sh2.clear();
  });

  test('cross-atSign lookup:all relays appMetadata', () async {
    // appMetadata landed in atServer 3.14.0. This pack runs against
    // long-lived atSigns which may be older, and the sharing server parses
    // the `:appMetadata:` fragment while the looking-up server relays the
    // response, so both have to support it.
    Version atSign1ServerVersion = Version.parse(await sh1.getVersion());
    if (atSign1ServerVersion < Version(3, 14, 0)) {
      print(
          'Found $atSign_1 with server version: $atSign1ServerVersion. This test is only applicable for server version at least 3.14.0. Skipping the test');
      return;
    }
    Version atSign2ServerVersion = Version.parse(await sh2.getVersion());
    if (atSign2ServerVersion < Version(3, 14, 0)) {
      print(
          'Found $atSign_2 with server version: $atSign2ServerVersion. This test is only applicable for server version at least 3.14.0. Skipping the test');
      return;
    }

    final key = 'appmeta-x-${Uuid().v4()}';

    // @first shares a key with @second, carrying appMetadata.
    await sh1.writeCommand(
        'update:appMetadata:$encodedAppMetadata:$atSign_2:$key$atSign_1'
        ' shared-value');
    String response = await sh1.read();
    print('update verb response : $response');
    expect(response, contains(RegExp(r'data:\d+')),
        reason: 'shared-key update should return a commitId');

    // @second looks it up through its own server — the real remote path.
    await sh2.writeCommand('lookup:all:$key$atSign_1');
    response = (await sh2.read(timeoutMillis: 10000)).replaceFirst('data:', '');
    print('lookup:all verb response : $response');
    final atData = jsonDecode(response);
    expect(atData['data'], 'shared-value');

    final appMetadata = atData['metaData']['appMetadata'];
    expect(appMetadata, isNotNull,
        reason: 'appMetadata absent from cross-atSign lookup:all response');
    expect(appMetadata['providerId'], 'acme_provider');
    expect(appMetadata['keyId'], 'k-123');
    expect(appMetadata['mode'], 'hpke');
  }, timeout: Timeout(Duration(minutes: 3)));
}
