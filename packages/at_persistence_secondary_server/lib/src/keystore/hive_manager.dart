import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_utils.dart';
import 'package:cron/cron.dart';
import 'package:hive/hive.dart';

import 'hive_base.dart';

class HivePersistenceManager with HiveBase {
  final logger = AtSignLogger('HivePersistenceManager');

  final String? _atsign;

  String? get atsign => _atsign;
  late String _boxName;

  HivePersistenceManager(this._atsign);

  final Cron _cron = Cron();
  final Random _random = Random();

  @override
  Future<void> initialize() async {
    try {
      if (!Hive.isAdapterRegistered(AtDataAdapter().typeId)) {
        Hive.registerAdapter(AtDataAdapter());
      }
      if (!Hive.isAdapterRegistered(AtMetaDataAdapter().typeId)) {
        Hive.registerAdapter(AtMetaDataAdapter());
      }
      if (!Hive.isAdapterRegistered(PublicKeyHashAdapter().typeId)) {
        Hive.registerAdapter(PublicKeyHashAdapter());
      }

      var secret = await _getHiveSecretFromFile(_atsign!, storagePath);
      _boxName = AtUtils.getShaForAtSign(_atsign!);
      await super.openBox(_boxName, hiveSecret: secret);
    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: $e');
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    } catch (error) {
      logger.severe('AtPersistence().init error: $error');
      rethrow;
    }
  }

//  Future<void> openVault(String atsign,
//      {List<int>? hiveSecret, bool isLazy = false}) async {
//    try {
//      // assert(hiveSecret != null);
//      hiveSecret ??= _secret;
//      atsign = atsign.trim().toLowerCase().replaceAll(' ', '');
//      if (_debug) {
//        logger.finer('AtPersistence.openVault received atsign: $atsign');
//      }
//      _atsign = atsign;
//      _boxName = AtUtils.getShaForAtSign(atsign);
//      if (_isLazy) {
//        await Hive.openLazyBox(_boxName,
//            encryptionCipher: HiveAesCipher(hiveSecret!));
//      } else {
//        await Hive.openBox(_boxName,
//            encryptionCipher: HiveAesCipher(hiveSecret!));
//      }
//      if (_debug) {
//        logger.finer('AtPersistence.openVault opened Hive box:_boxName');
//      }
//      if (_getBox().isOpen) {
//        logger.info('KeyStore initialized successfully.');
//      }
//    } on Exception catch (exception) {
//      logger.severe('AtPersistence.openVault exception: $exception');
//    } catch (error) {
//      logger.severe('AtPersistence().openVault error: $error');
//    }
//  }

  Future<List<int>?> _getHiveSecretFromFile(
      String atsign, String storagePath) async {
    List<int>? secretAsUint8List;
    try {
      atsign = atsign.trim().toLowerCase();
      logger.finest(
          'getHiveSecretFromFile fetching hiveSecretString for $atsign from file');
      var path = storagePath;
      var fileName = '${AtUtils.getShaForAtSign(atsign)}.hash';
      var filePath = '$path/$fileName';
      logger.finest('getHiveSecretFromFile found filePath: $filePath');
      String hiveSecretString;
      var exists = File(filePath).existsSync();
      if (exists) {
        hiveSecretString = File(filePath).readAsStringSync();
        if (hiveSecretString.isEmpty) {
          secretAsUint8List = _generatePersistenceSecret();
          hiveSecretString = String.fromCharCodes(secretAsUint8List);
          File(filePath).writeAsStringSync(hiveSecretString);
        } else {
          secretAsUint8List = Uint8List.fromList(hiveSecretString.codeUnits);
        }
      } else {
        secretAsUint8List = _generatePersistenceSecret();
        hiveSecretString = String.fromCharCodes(secretAsUint8List);
        var newFile = await File(filePath).create(recursive: true);
        newFile.writeAsStringSync(hiveSecretString);
      }
    } on Exception catch (exception) {
      logger.severe('getHiveSecretFromFile exception: $exception');
    } catch (error) {
      logger.severe('getHiveSecretFromFile caught error: $error');
    }
    return secretAsUint8List;
  }

  //TODO change into to Duration and construct cron string dynamically
  void scheduleKeyExpireTask(int? runFrequencyMins, {Duration? runTimeInterval, bool skipCommits = false}) {
    logger.finest('scheduleKeyExpireTask starting cron job.');
    Schedule schedule;
    if(runTimeInterval != null){
      schedule = Schedule(seconds: runTimeInterval.inSeconds);
    } else {
      schedule = Schedule.parse('*/$runFrequencyMins * * * *');
    }
    _cron.schedule(schedule, () async {
      await Future.delayed(Duration(seconds: _random.nextInt(12)));
      var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
          .getSecondaryPersistenceStore(_atsign)!
          .getSecondaryKeyStore()!;
      await hiveKeyStore.deleteExpiredKeys(skipCommit: skipCommits);
    });
  }

  List<int> _generatePersistenceSecret() {
    return Hive.generateSecureKey();
  }
}
