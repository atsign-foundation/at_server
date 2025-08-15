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
  AtSignLogger.defaultLoggingHandler = AtSignLogger.stdErrLoggingHandler;
  AtSignLogger.root_level='shout';
  final AtSignLogger logger = AtSignLogger(' at_directory_test ');
  logger.level='info';
  List<String> atSigns = at_demo_data.allAtsigns
    ..addAll(at_demo_data.apkamAtsigns)
    ..remove('anonymous');
  final root = 'vip.ve.atsign.zone';

  test('lookup existing atSign via 64', () async {
    List<Future> futures = [];
    for (final atSign in atSigns) {
      final saf = CacheableSecondaryAddressFinder(root, 64);
      futures.add(saf.findSecondary(atSign));
    }
    final responses = await Future.wait(futures);
    logger.info('${responses.length} of ${atSigns.length} OK');
  });

  test('lookup non-existent atSign avia 64', () async {
    List<Future> futures = [];
    for (final atSign in atSigns.map((e) => '${e}_nope')) {
      final saf = CacheableSecondaryAddressFinder(root, 64);
      futures.add(expectLater(saf.findSecondary(atSign),
          throwsA(isA<SecondaryNotFoundException>())));
    }
    final responses = await Future.wait(futures);
    logger.info('${responses.length} of ${atSigns.length} OK');
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
    logger.info('${responses.length} of ${atSigns.length} OK');
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
    logger.info('${responses.length} of ${atSigns.length} OK');
  });

  Future<(int, String)> httpClientGet(Uri uri) async {
    final SecurityContext context = SecurityContext(withTrustedRoots: true);
    context.setAlpnProtocols(['http/1.1'], false);
    final HttpClient client = HttpClient(context: context);

    HttpClientRequest request = await client.getUrl(uri);
    HttpClientResponse response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
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
    Future<void> doit(String atSign) async {
      final pskFromAtLookup = await AtLookupImpl(atSign, root, 64)
          .executeCommand('lookup:signing_publickey$atSign\n');

      final (statusCode, body) = await httpClientGet(Uri.https(root, '/$atSign/signing_publickey'));

      expect(statusCode, HttpStatus.ok);
      final pskFromHttpRedirect = body;
      expect(pskFromHttpRedirect, startsWith('data:'));
      expect(pskFromHttpRedirect, pskFromAtLookup);
    }

    List<Future> futures = [];
    for (final atSign in atSigns) {
      futures.add(doit(atSign));
    }

    final responses = await Future.wait(futures);
    logger.info('${responses.length} of ${atSigns.length} OK');
  });
}
