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
  AtSignLogger.root_level = 'shout';
  final root = 'vip.ve.atsign.zone';

  group('basic atDirectory tests', () {
    List<String> atSigns = at_demo_data.allAtsigns
      ..addAll(at_demo_data.apkamAtsigns)
      ..remove('anonymous');

    test('lookup existing atSign via 64', () async {
      List<Future> futures = [];
      for (final atSign in atSigns) {
        final saf = CacheableSecondaryAddressFinder(root, 64);
        futures.add(saf.findSecondary(atSign));
      }
      final responses = await Future.wait(futures);
      stderr.writeln('${responses.length} of ${atSigns.length} OK');
    });

    test('lookup non-existent atSign avia 64', () async {
      List<Future> futures = [];
      for (final atSign in atSigns.map((e) => '${e}_nope')) {
        final saf = CacheableSecondaryAddressFinder(root, 64);
        futures.add(expectLater(saf.findSecondary(atSign),
            throwsA(isA<SecondaryNotFoundException>())));
      }
      final responses = await Future.wait(futures);
      stderr.writeln('${responses.length} of ${atSigns.length} OK');
    });

    test('lookup existing atSign via https', () async {
      List<Future> futures = [];
      for (final atSign in atSigns) {
        final Uri url = Uri.https(root, atSign);
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
        final Uri url = Uri.https(root, atSign);
        futures.add(expectLater(
          http.get(url).then((response) => response.statusCode),
          completion(HttpStatus.notFound),
        ));
      }
      final responses = await Future.wait(futures);
      stderr.writeln('${responses.length} of ${atSigns.length} OK');
    });
  });

  group('atDirectory redirect tests', () {
    List<String> atSigns = at_demo_data.allAtsigns
      ..addAll(at_demo_data.apkamAtsigns)
      ..remove('anonymous');

    Future<bool> getAndCompareSigningKeyData(String atSign) async {
      final String command = 'lookup:signing_publickey$atSign';
      final atLookup = AtLookupImpl(atSign, root, 64);
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
          Uri.https(root, '/$atSign/signing_publickey'));

      expect(statusCode, HttpStatus.ok);
      expect(pskFromHttpRedirect, pskFromAtLookup);

      return true;
    }

    Future<bool> getAndComparePublicKeyMetadata(
        String key, String atSign) async {
      final String command = 'lookup:meta:$key$atSign';
      final atLookup = AtLookupImpl(atSign, root, 64);
      String atMetaDataFromAtLookup;
      try {
        atMetaDataFromAtLookup = (await atLookup.executeCommand('$command\n'))!;
        if (atMetaDataFromAtLookup.startsWith('data:')) {
          atMetaDataFromAtLookup =
              atMetaDataFromAtLookup.replaceFirst('data:', '');
        }
      } finally {
        await atLookup.close();
      }

      final (statusCode, atMetaDataFromHttpGet) = await dartIoHttpClientGet(
          Uri.https(root, '/$atSign/$key?at_rt=meta'));

      expect(statusCode, HttpStatus.ok);
      expect(atMetaDataFromHttpGet, atMetaDataFromAtLookup);

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
      int successes = 0;
      List<Future<bool>> futures = [];
      for (final atSign in atSigns) {
        futures.add(getAndCompareSigningKeyData(atSign));
      }

      List<bool> outcomes = await Future.wait(futures);
      for (final b in outcomes) {
        if (b) {
          successes++;
        }
      }

      if (successes != atSigns.length) {
        throw Exception('Only $successes successes out of ${atSigns.length}');
      }
      stderr.writeln('$successes successes out of ${atSigns.length} OK');
    });

    test('lookup the metadata of some key via https with redirect', () async {
      int successes = 0;
      List<Future<bool>> futures = [];
      // List<String> atSigns = ['@client'];
      List<String> atSigns = at_demo_data.allAtsigns;
      for (final atSign in atSigns) {
        futures.add(getAndComparePublicKeyMetadata('publickey', atSign));
      }

      List<bool> outcomes = await Future.wait(futures);
      for (final b in outcomes) {
        if (b) {
          successes++;
        }
      }

      if (successes != atSigns.length) {
        throw Exception('Only $successes successes out of ${atSigns.length}');
      }
      stderr.writeln('$successes successes out of ${atSigns.length} OK');
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
Future<(int, String)> dartIoHttpClientGet(Uri uri, {HttpClient? client}) async {
  bool shouldClose = client == null;
  client ??= newHttpClient();
  try {
    client.idleTimeout = Duration(seconds: 0);

    HttpClientRequest request = await client.getUrl(uri);
    request.headers.persistentConnection = false;
    HttpClientResponse response = await request.close();
    final (statusCode, body) =
        (response.statusCode, await response.transform(utf8.decoder).join());
    return (statusCode, body);
  } finally {
    if (shouldClose) {
      client.close(force: true);
    }
  }
}

HttpClient newHttpClient() {
  final SecurityContext context = SecurityContext(withTrustedRoots: true);
  context.setAlpnProtocols(['http/1.1'], false);
  return HttpClient(context: context);
}
