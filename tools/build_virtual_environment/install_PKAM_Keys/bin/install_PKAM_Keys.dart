import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart' as at_demo_data;
import 'package:at_lookup/at_lookup.dart';
import 'package:at_utils/at_utils.dart';

final String rootDomain = 'vip.ve.atsign.zone';
final int rootPort =
    int.tryParse(Platform.environment['rootServerPort'] ?? '') ?? 64;
final SecondaryAddressFinder saf =
    CacheableSecondaryAddressFinder(rootDomain, rootPort);
late final AtSignLogger logger;

// we'll try to look up the atSign in the atDirectory every 5 seconds,
// up to 24 times i.e. for up to 2 minutes
final int retryDelay = 5;
final int tries = 24;

void main(List<String> args) async {
  AtSignLogger.defaultLoggingHandler = AtSignLogger.stdErrLoggingHandler;
  if (args.contains('--debug')) {
    AtSignLogger.root_level = 'finest';
  } else if (args.contains('-v') || args.contains('--verbose')) {
    AtSignLogger.root_level = 'info';
  } else {
    AtSignLogger.root_level = 'warning';
  }
  logger = AtSignLogger(' install_PKAM_Keys ');

  logger.shout('Starting. Will wait for up to 2 minutes for atSigns to be'
      ' registered in the VE atDirectory');
  List<Future<void>> futures = [];

  futures.addAll(
      at_demo_data.allAtsigns.map((String atSign) => cramAndPkamAuth(atSign)));

  futures.addAll(
      at_demo_data.apkamAtsigns.map((String atSign) => cramAuthOnly(atSign)));

  await Future.wait(futures);

  exit(0);
}

Future<bool> atSignIsInAtDirectory(String atSign) async {
  for (int i = 0; i < tries; i++) {
    try {
      logger.info('Looking up $atSign in atDirectory $rootDomain:$rootPort}');
      await saf.findSecondary(atSign);
      logger.shout('Found $atSign in atDirectory $rootDomain:$rootPort}');
      return true;
    } catch (_) {
      await Future.delayed(Duration(seconds: retryDelay));
    }
  }
  logger.warning('$atSign not in atDirectory after ${tries * retryDelay} secs');
  return false;
}

Future<void> cramAuthOnly(String atSign) async {
  if (!await atSignIsInAtDirectory(atSign)) {
    return;
  }
  try {
    final atLookUp = AtLookupImpl(
      atSign,
      rootDomain,
      rootPort,
      secondaryAddressFinder: saf,
    );
    var isCramAuthSuccessful =
        await atLookUp.cramAuthenticate(at_demo_data.cramKeyMap[atSign]!);
    if (!isCramAuthSuccessful) {
      logger.severe('CRAM Authentication failed for $atSign');
      return;
    }
    logger.shout('cramAuthOnly successful for $atSign');
    await atLookUp.close();
  } on Exception catch (e) {
    logger
        .severe('error while cram auth for $atSign exception: ${e.toString()}');
  }
}

Future<void> cramAndPkamAuth(String atSign) async {
  if (atSign == 'anonymous') {
    return;
  }
  if (!await atSignIsInAtDirectory(atSign)) {
    return;
  }
  try {
    final atLookUp = AtLookupImpl(
      atSign,
      'vip.ve.atsign.zone',
      rootPort,
      secondaryAddressFinder: saf,
    );
    var isCramAuthSuccessful =
        await atLookUp.cramAuthenticate(at_demo_data.cramKeyMap[atSign]!);
    if (!isCramAuthSuccessful) {
      logger.severe('CRAM Authentication failed for $atSign');
      return;
    }
    logger.info('CRAM Authentication is successful for $atSign');

    // Set PKAM public key
    var command =
        'update:privatekey:at_pkam_publickey ${at_demo_data.pkamPublicKeyMap[atSign]}\n';
    var response = await atLookUp.executeCommand(command, auth: true);
    if (response == 'data:-1') {
      logger.info('Setting of PKAM public key for $atSign is successful');
    } else {
      logger.severe('Failed to update PKAM public key for $atSign');
      return;
    }

    // Set encryption public key
    command =
        'update:public:publickey$atSign ${at_demo_data.encryptionPublicKeyMap[atSign]}\n';
    response = await atLookUp.executeCommand(command, auth: true);
    if (response!.startsWith('data:') && response != 'data:null') {
      logger.info('Setting of encryption public key for $atSign is successful');
    } else {
      logger.severe('Failed to update encryption public key for $atSign');
      return;
    }

    // Set pkamInstalled key to "yes"
    command = 'update:public:pkaminstalled$atSign yes\n';
    response = await atLookUp.executeCommand(command, auth: true);
    if (response!.startsWith('data:') && response != 'data:null') {
      logger.info('Set pkaminstalled key for $atSign is successful');
    } else {
      logger.info('Failed to update pkaminstalled key for $atSign');
      return;
    }

    logger.shout('cramAndPkamAuth successful for $atSign');

    await atLookUp.close();
  } on Exception catch (e) {
    logger.info(
        'error while setting keys for $atSign exception: ${e.toString()}');
  }
}
