import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart' as at_demo_data;

void main(List<String> arguments) async {
  print(r'#!/bin/bash');
  print(r'cd /tmp/setup');

  int port = 25000;
  List<String> atSigns = [
    ...at_demo_data.allAtsigns,
    ...at_demo_data.apkamAtsigns,
  ];
  for (final String atSign in atSigns) {
    if (atSign == 'anonymous') {
      continue;
    }
    print('./createConf '
        '${atSign.substring(1).padRight(20)}'
        '${port.toString().padRight(12)}'
        '${at_demo_data.cramKeyMap[atSign]}');
    port++;
  }

  exit(0);
}
