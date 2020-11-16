import 'dart:io';
import 'dart:typed_data';
import 'package:at_utils/at_utils.dart';
import 'package:cron/cron.dart';
import 'package:at_persistence_secondary_server/src/model/at_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_meta_data.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class HivePersistenceManager {
  static final HivePersistenceManager _singleton =
      HivePersistenceManager._internal();

  final bool _debug = false;

  bool _registerAdapters = false;

  HivePersistenceManager._internal();

  factory HivePersistenceManager.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('HivePersistenceManager');

  Box _box;

  Box get box => _box;
  String _atsign;

  String get atsign => _atsign;
  String _boxName;
  var _secret;

  Future<bool> init(String atSign, String storagePath) async {
    var success = false;
    try {
      assert(storagePath != null && storagePath != '');
      if (_debug) {
        logger.finer('AtPersistence.init received storagePath: ' + storagePath);
      }
      Hive.init(storagePath);
      if (!_registerAdapters) {
        Hive.registerAdapter(AtDataAdapter());
        Hive.registerAdapter(AtMetaDataAdapter());
        _registerAdapters = true;
      }

      var secret = await _getHiveSecretFromFile(atSign, storagePath);
      _secret = secret;
      success = true;
    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: ' + e.toString());
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    } catch (error) {
      logger.severe('AtPersistence().init error: ' + error.toString());
      rethrow;
    }
    return success;
  }

  Future<Box> openVault(String atsign, {List<int> hiveSecret}) async {
    try {
      // assert(hiveSecret != null);
      hiveSecret ??= _secret;
      if (_debug) {
        logger.finer('AtPersistence.openVault received hiveSecret: ' +
            hiveSecret.toString());
      }
      assert(atsign != null && atsign != '');
      atsign = atsign.trim().toLowerCase().replaceAll(' ', '');
      if (_debug) {
        logger.finer('AtPersistence.openVault received atsign: $atsign');
      }
      _atsign = atsign;
      _boxName = AtUtils.getShaForAtSign(atsign);
      // ignore: omit_local_variable_types
      var hiveBox = await Hive.openBox(_boxName, encryptionKey: hiveSecret,
          compactionStrategy: (entries, deletedEntries) {
        return deletedEntries > 50;
      });
      _box = hiveBox;
      if (_debug) {
        logger.finer(
            'AtPersistence.openVault opened Hive box:' + _box.toString());
      }
    } on Exception catch (exception) {
      logger.severe('AtPersistence.openVault exception: $exception');
    } catch (error) {
      logger.severe('AtPersistence().openVault error: $error');
    }
    return _box;
  }

  Future<List<int>> _getHiveSecretFromFile(
      String atsign, String storagePath) async {
    List<int> secretAsUint8List;
    try {
      assert(atsign != null && atsign != '');
      atsign = atsign.trim().toLowerCase();
      if (_debug) {
        logger.finer('getHiveSecretFromFile fetching hiveSecretString for ' +
            atsign +
            ' from file');
      }
      var path = storagePath;
      var fileName = AtUtils.getShaForAtSign(atsign) + '.hash';
      var filePath = path + '/' + fileName;
      if (_debug) {
        logger.finer('getHiveSecretFromFile found filePath: ' + filePath);
      }
      String hiveSecretString;
      var exists = File(filePath).existsSync();
      if (exists) {
        if (_debug) print('AtServer.getHiveSecretFromFile file found');
        hiveSecretString = await File(filePath).readAsStringSync();
        if (hiveSecretString == null) {
          secretAsUint8List = _generatePersistenceSecret();
          hiveSecretString = String.fromCharCodes(secretAsUint8List);
          File(filePath).writeAsStringSync(hiveSecretString);
        } else {
          secretAsUint8List = Uint8List.fromList(hiveSecretString.codeUnits);
        }
      } else {
        if (_debug) print('getHiveSecretFromFile no file found');
        secretAsUint8List = _generatePersistenceSecret();
        hiveSecretString = String.fromCharCodes(secretAsUint8List);
        var newFile = await File(filePath).create(recursive: true);
        newFile.writeAsStringSync(hiveSecretString);
      }
    } on Exception catch (exception) {
      logger.severe('getHiveSecretFromFile exception: ' + exception.toString());
    } catch (error) {
      logger.severe('getHiveSecretFromFile caught error: $error');
    }
    return secretAsUint8List;
  }

  void scheduleKeyExpireTask(int runFrequencyMins) {
    var cron = Cron();
    cron.schedule(Schedule.parse('*/${runFrequencyMins} * * * *'), () async {
      var hiveKeyStore = SecondaryKeyStoreManager.getInstance().getKeyStore();
      hiveKeyStore.deleteExpiredKeys();
    });
  }

  List<int> _generatePersistenceSecret() {
    return Hive.generateSecureKey();
  }
}
