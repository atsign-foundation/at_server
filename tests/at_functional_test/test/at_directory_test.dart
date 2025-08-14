import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:at_demo_data/at_demo_data.dart' as at_demo_data;
import 'package:http/http.dart' as http;

void main() {
  AtSignLogger.defaultLoggingHandler = AtSignLogger.stdErrLoggingHandler;
  final AtSignLogger logger = AtSignLogger(' at_directory_test ');
  List<String> atSigns = at_demo_data.allAtsigns
    ..addAll(at_demo_data.apkamAtsigns)
    ..remove('anonymous');
  final domain = 'vip.ve.atsign.zone';
  final saf = CacheableSecondaryAddressFinder(domain, 64);

  test('lookup existing atSign via 64', () async {
    List<Future> futures = [];
    for (final atSign in atSigns) {
      futures.add(saf.findSecondary(atSign));
    }
    final responses = await Future.wait(futures);
    logger.info('${responses.length} of ${atSigns.length} OK');
  });

  test('lookup non-existent atSign avia 64', () async {
    List<Future> futures = [];
    for (final atSign in atSigns.map((e) => '${e}_nope')) {
      futures.add(expectLater(saf.findSecondary(atSign),
          throwsA(isA<SecondaryNotFoundException>())));
    }
    final responses = await Future.wait(futures);
    logger.info('${responses.length} of ${atSigns.length} OK');
  });

  test('lookup existing atSign via https', () async {
    List<Future> futures = [];
    for (final atSign in atSigns) {
      final Uri url = Uri.https(domain, atSign);
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
      final Uri url = Uri.https(domain, atSign);
      futures.add(expectLater(
        http.get(url).then((response) => response.statusCode),
        completion(HttpStatus.notFound),
      ));
    }
    final responses = await Future.wait(futures);
    logger.info('${responses.length} of ${atSigns.length} OK');
  });

  test('lookup signing_publickey via https', () async {
    final atSign = '@gary';

    final Uri redirectingUrl = Uri.https(domain, '/$atSign/signing_publickey');
    final String pskResponseViaHttps = (await http.get(redirectingUrl)).body;

    final AtLookupImpl al =
        AtLookupImpl(atSign, domain, 64, secondaryAddressFinder: saf);
    final pskResponseViaAtProtocolSocket =
        await al.executeCommand('lookup:signing_publickey$atSign');

    expect(pskResponseViaHttps, pskResponseViaAtProtocolSocket);
  });
}
