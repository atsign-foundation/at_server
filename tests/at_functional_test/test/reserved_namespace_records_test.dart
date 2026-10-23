import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Catalogue: features/keys/reserved_namespace_records.feature
///
/// @xavier plays @alice and @jeremy plays @bob. @xavier's pkam client is
/// enrollment primary. Each test names its keys with a prefix of its own.
void main() {
  const String xavier = '@xavier';
  const String jeremy = '@jeremy';
  const String rootDomain = 'vip.ve.atsign.zone';
  final int rootPort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '') ?? 64;

  late OutboundConnectionFactory cram;
  late OutboundConnectionFactory pkam;

  Future<OutboundConnectionFactory> clientOf(String atSign,
      {required AuthType authType}) async {
    final SecondaryAddress address =
        await CacheableSecondaryAddressFinder(rootDomain, rootPort)
            .findSecondary(atSign);
    final OutboundConnectionFactory client = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, address.host, address.port);
    expect((await client.authenticateConnection(authType: authType)).trim(),
        'data:success',
        reason: 'the client of $atSign must authenticate by ${authType.name}');
    return client;
  }

  Future<String> send(OutboundConnectionFactory client, String command) async =>
      (await client.sendRequestToServer(command)).trim();

  String prefix() => 'r${Uuid().v4().substring(0, 8)}';

  setUpAll(() async {
    cram = await clientOf(xavier, authType: AuthType.cram);
    pkam = await clientOf(xavier, authType: AuthType.pkam);
  });

  tearDownAll(() async {
    await cram.close();
    await pkam.close();
  });

  group(
      "An atSign's own client may not change a record in a reserved "
      'namespace', () {
    for (final (
          String auth,
          String Function(String) command,
          String Function(String) record
        ) in [
      (
        'cram',
        (p) => 'update:$p.__global$xavier v',
        (p) => '$p.__global$xavier'
      ),
      (
        'pkam',
        (p) => 'update:$p.__private$xavier v',
        (p) => '$p.__private$xavier'
      ),
      (
        'pkam',
        (p) => 'update:public:$p.__foo$xavier v',
        (p) => 'public:$p.__foo$xavier'
      ),
      (
        'cram',
        (p) => 'update:$jeremy:$p.__global$xavier v',
        (p) => '$jeremy:$p.__global$xavier'
      ),
    ]) {
      test(auth, () async {
        final OutboundConnectionFactory client = auth == 'cram' ? cram : pkam;
        final String p = prefix();

        expect(await send(client, command(p)), contains('AT0009'));

        expect(await send(cram, 'llookup:${record(p)}'),
            isNot(startsWith('data:v')),
            reason: 'the record is unchanged');
        expect(
            await send(client, 'update:$p.wavi$xavier v'), startsWith('data:'),
            reason: 'it keeps its connection');
      });
    }
  });

  test(
      "An atSign's own client may not change a record in a reserved namespace "
      'inside a batch', () async {
    final String p = prefix();

    final String answer = await send(
        cram,
        'batch:${jsonEncode([
              {'id': 1, 'command': 'update:$p.__global$xavier v'},
              {'id': 2, 'command': 'update:$p.wavi$xavier v'},
            ])}');

    final List<dynamic> entries = jsonDecode(answer.replaceFirst('data:', ''));
    expect(entries[0]['response']['error_code'], 'AT0009');
    expect(entries[1]['response']['error_code'], isNull);
    expect(await send(cram, 'llookup:$p.wavi$xavier'), 'data:v');
  });

  test('An enrollment changes records in its own per-enrollment namespace',
      () async {
    for (final OutboundConnectionFactory client in [pkam, cram]) {
      final String p = prefix();
      final String key = '$p.primary.a.__e$xavier';

      expect(await send(client, 'update:$key v'), startsWith('data:'));
      expect(await send(client, 'llookup:$key'), 'data:v');
      expect(await send(client, 'delete:$key'), startsWith('data:'));
    }
  });

  test(
      "An enrollment's records in its own per-enrollment namespace are never "
      'for another atSign', () async {
    final String p = prefix();

    expect(await send(pkam, 'update:$jeremy:$p.primary.a.__e$xavier v'),
        contains('AT0009'));
  });

  test('A stored passcode is read only through otp:', () async {
    for (final String command in [
      'llookup:private:spp.__otp$xavier',
      'lookup:private:spp.__otp$xavier',
      'lookup:all:private:spp$xavier',
    ]) {
      expect(await send(cram, command), contains('AT0009'), reason: command);
    }
  });
}
