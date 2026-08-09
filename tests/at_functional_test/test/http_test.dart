import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:at_demo_data/at_demo_data.dart' as at_demo_data;
import 'package:http/http.dart' as http;

// All of the tests here are serving two needs
// (1) the functionality
// (2) race conditions, as in each test we are executing requests for all of
//     the atSigns in the ve - but in parallel rather than sequentially.
void main() {
  List<String> atSigns = at_demo_data.allAtsigns.getRange(1, 21).toList()
    ..remove('anonymous');

  AtSignLogger.root_level = 'shout';
  final root = 'vip.ve.atsign.zone';
  // When the VE runs on a shifted base port (VIRTUALENV_BASE_PORT), the
  // atDirectory binds to BASE and serves HTTPS on BASE + 98 (see the ve
  // entrypoint); otherwise the defaults 64 / 443.
  final basePort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '');
  final rootPort = basePort ?? 64;
  // VIRTUALENV_ATDIRECTORY_HTTPS_PORT overrides the HTTPS port outright — used
  // when the atServer serves HTTP GET-for-key on its OWN TLS port and there is
  // no co-located port-64 atDirectory (an atServer that co-locates its HTTP
  // GET-for-key surface on its own TLS port). Otherwise the ve's BASE + 98 (or
  // the default 443) applies.
  final httpsPort =
      int.tryParse(Platform.environment['VIRTUALENV_ATDIRECTORY_HTTPS_PORT'] ?? '') ??
          (basePort != null ? basePort + 98 : 443);

  // When that override is set, the atProtocol-lookup half of the redirect tests
  // must connect straight to the atServer (root:httpsPort) rather than resolving
  // each atSign via the atDirectory; a fixed finder points every atSign there.
  // Unset (ve) => null => AtLookupImpl's default CacheableSecondaryAddressFinder.
  final SecondaryAddressFinder? directLookupFinder =
      Platform.environment.containsKey('VIRTUALENV_ATDIRECTORY_HTTPS_PORT')
          ? _FixedSecondaryAddressFinder(root, httpsPort)
          : null;

  // The basic atDirectory tests hit the port-64 secondary-address lookup and the
  // root HTTPS lookup; skip them where the atServer has no co-located
  // atDirectory: SKIP_BASIC_ATDIRECTORY_TESTS=true.
  final skipBasicAtDirectory =
      (Platform.environment['SKIP_BASIC_ATDIRECTORY_TESTS'] ?? '').toLowerCase() ==
          'true';

  group('basic atDirectory tests', () {
    test('lookup existing atSign via 64', () async {
      List<Future> futures = [];
      for (final atSign in atSigns) {
        final saf = CacheableSecondaryAddressFinder(root, rootPort);
        futures.add(saf.findSecondary(atSign));
      }
      final responses = await Future.wait(futures);
      stderr.writeln('${responses.length} of ${atSigns.length} OK');
    });

    test('lookup non-existent atSign avia 64', () async {
      List<Future> futures = [];
      for (final atSign in atSigns.map((e) => '${e}_nope')) {
        final saf = CacheableSecondaryAddressFinder(root, rootPort);
        futures.add(expectLater(saf.findSecondary(atSign),
            throwsA(isA<SecondaryNotFoundException>())));
      }
      final responses = await Future.wait(futures);
      stderr.writeln('${responses.length} of ${atSigns.length} OK');
    });

    test('lookup existing atSign via https', () async {
      List<Future> futures = [];
      for (final atSign in atSigns) {
        final Uri url = Uri.https('$root:$httpsPort', atSign);
        futures.add(expectLater(
          http.get(url).then((response) => response.statusCode),
          completion(HttpStatus.ok),
        ));
      }
      final responses = await Future.wait(futures);
      stderr.writeln('${responses.length} of ${atSigns.length} OK');
    });

    test('lookup non-existent atSign via https', () async {
      List<Future> futures = [];
      for (final atSign in atSigns.map((e) => '${e}_nope')) {
        final Uri url = Uri.https('$root:$httpsPort', atSign);
        futures.add(expectLater(
          http.get(url).then((response) => response.statusCode),
          completion(HttpStatus.notFound),
        ));
      }
      final responses = await Future.wait(futures);
      stderr.writeln('${responses.length} of ${atSigns.length} OK');
    });
  },
      skip: skipBasicAtDirectory
          ? 'atDirectory port-64 / HTTPS lookup — no co-located atDirectory'
          : null);

  group('atDirectory redirect tests', () {
    Future<bool> getAndCompareServerSigningKeyData(String atSign) async {
      final String command = 'lookup:signing_publickey$atSign';
      final atLookup = AtLookupImpl(atSign, root, rootPort,
          secondaryAddressFinder: directLookupFinder);
      String pskFromAtLookup;
      try {
        pskFromAtLookup = (await atLookup.executeCommand('$command\n'))!;
        if (pskFromAtLookup.startsWith('data:')) {
          pskFromAtLookup = pskFromAtLookup.replaceFirst('data:', '');
        }
      } finally {
        await atLookup.close();
      }

      final (statusCode, pskFromHttpRedirect) = await dartIoHttpClientGet(
          Uri.https('$root:$httpsPort', '/$atSign/signing_publickey'));

      expect(statusCode, HttpStatus.ok);
      expect(pskFromHttpRedirect, pskFromAtLookup);

      return true;
    }

    Future<bool> getAndCompareServerSigningKeyMetadata(String atSign) async {
      final String command = 'lookup:meta:signing_publickey$atSign';
      final atLookup = AtLookupImpl(atSign, root, rootPort,
          secondaryAddressFinder: directLookupFinder);
      String atMetaDataFromAtLookup = '';
      try {
        atMetaDataFromAtLookup = (await atLookup.executeCommand('$command\n'))!;
        if (atMetaDataFromAtLookup.startsWith('data:')) {
          atMetaDataFromAtLookup =
              atMetaDataFromAtLookup.replaceFirst('data:', '');
        }
      } finally {
        try {
          await atLookup.close();
        } catch (_) {}
      }

      final (statusCode, atMetaDataFromHttpGet) = await dartIoHttpClientGet(
          Uri.https('$root:$httpsPort', '/$atSign/signing_publickey', {'at_rt': 'meta'}));

      expect(statusCode, HttpStatus.ok);
      expect(atMetaDataFromHttpGet, atMetaDataFromAtLookup);

      stderr.writeln('getAndCompareServerSigningKeyMetadata: $atSign OK');

      return true;
    }

    // For each atSign
    // - Fetch public:signing_publickey from each atServer via AtLookup
    // - Fetch it from https://<rootHost>/$atSign/signing_publickey
    //   - The presence of the additional 'signing_publickey' in the uri path
    //     tells the atDirectory that it should
    //     - 1) look up the atSign's atServer's host and port, and if successful
    //     - 2) Return a 302 with the location header set to https:<atServerHostAndPort>/signing_publickey
    //   - Default behaviour of the Dart http clients (whether HttpClient from dart.io
    //     or Client from the http package) is to follow GET redirects
    // - Assert that the values we fetched via AtLookup and http are identical
    test('lookup signing_publickey via https with redirect', () async {
      for (final atSign in atSigns) {
        await getAndCompareServerSigningKeyData(atSign);
      }
    });

    test('lookup the metadata of some key via https with redirect', () async {
      for (final atSign in atSigns) {
        await getAndCompareServerSigningKeyMetadata(atSign);
      }
    });
  });
}

/// - Annoyingly, the Dart http clients do not set alpn protocols
/// - And the client in the `http` package does not allow setting a context;
/// it uses the default context. We can setAlpnProtocols in the default
/// context, but this means every connection to the atServer uses those
/// protocols, so normal AtLookup connections fail
/// - So, we use dart.io's HttpClient which allows us to pass a context
/// - returns (statusCode, body)
Future<(int, String)> dartIoHttpClientGet(Uri uri) async {
  HttpClient client = newHttpClient();
  try {
    client.idleTimeout = Duration(seconds: 0);

    HttpClientRequest request = await client.getUrl(uri);
    request.headers.persistentConnection = false;
    HttpClientResponse response = await request.close();
    final (statusCode, body) =
        (response.statusCode, await response.transform(utf8.decoder).join());
    return (statusCode, body);
  } finally {
    client.close(force: true);
  }
}

HttpClient newHttpClient() {
  final SecurityContext context = SecurityContext(withTrustedRoots: true);
  context.setAlpnProtocols(['http/1.1'], false);
  return HttpClient(context: context);
}

/// A [SecondaryAddressFinder] that returns a fixed host:port for every atSign —
/// used when the atServer serves directly (atProtocol + HTTP GET-for-key on one
/// TLS port) and there is no atDirectory to resolve per-atSign addresses.
class _FixedSecondaryAddressFinder implements SecondaryAddressFinder {
  final String host;
  final int port;
  _FixedSecondaryAddressFinder(this.host, this.port);

  @override
  Future<SecondaryAddress> findSecondary(String atSign,
          {Duration? timeout}) async =>
      SecondaryAddress(host, port);
}
