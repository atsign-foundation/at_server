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

  test('lookup existing via 64', () async {
    for (final atSign in atSigns) {
      final saf = CacheableSecondaryAddressFinder('vip.ve.atsign.zone', 64);
      final addr = await saf.findSecondary(atSign);
      logger.info('atProtocol socket: $atSign: $addr');
    }
  });

  test('lookup non-existent via 64', () async {
    for (final atSign in atSigns.map((e) => '${e}_nope')) {
      final saf = CacheableSecondaryAddressFinder('vip.ve.atsign.zone', 64);
      await expectLater(saf.findSecondary(atSign),
          throwsA(isA<SecondaryNotFoundException>()));
    }
  });

  test('lookup existing via https', () async {
    for (final atSign in atSigns) {
      final Uri url = Uri.https('vip.ve.atsign.zone', atSign);
      http.Response response = await http.get(url);
      logger.info('https: $atSign: ${response.statusCode}: ${response.body}');
      expect(response.statusCode, HttpStatus.ok);
    }
  });

  test('lookup non-existent via https', () {});
}
