import 'package:at_persistence_secondary_server/src/model/at_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_metadata_builder.dart';
import 'package:at_utils/at_logger.dart';
import 'package:utf7/utf7.dart';

class HiveKeyStoreHelper {
  static final HiveKeyStoreHelper _singleton = HiveKeyStoreHelper._internal();

  HiveKeyStoreHelper._internal();

  factory HiveKeyStoreHelper.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('HiveKeyStoreHelper');

  String prepareKey(String key) {
    assert(key != null && key != '');
    key = key.trim().toLowerCase().replaceAll(' ', '');
    return Utf7.encode(key);
  }

  AtData prepareDataForCreate(AtData newData,
      {int ttl,
      int ttb,
      int ttr,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature,
      String sharedKeyStatus}) {
    var at_data = AtData();
    at_data.data = newData.data;
    at_data.metaData = AtMetadataBuilder(
            newAtMetaData: newData.metaData,
            ttl: ttl,
            ttb: ttb,
            ttr: ttr,
            ccd: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyStatus: sharedKeyStatus)
        .build();
    at_data.metaData.version = 0;
    return at_data;
  }

  AtData prepareDataForUpdate(AtData existingData, AtData newData,
      {int ttl,
      int ttb,
      int ttr,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature,
      String sharedKeyStatus}) {
    existingData.metaData = AtMetadataBuilder(
            newAtMetaData: newData.metaData,
            existingMetaData: existingData.metaData,
            ttl: ttl,
            ttb: ttb,
            ttr: ttr,
            ccd: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyStatus: sharedKeyStatus)
        .build();
    (existingData.metaData.version == null)
        ? existingData.metaData.version = 0
        : existingData.metaData.version += 1;
    existingData.data = newData.data;
    return existingData;
  }

  static bool hasValueChanged(AtData newData, AtData oldData) {
    assert(newData != null && oldData != null);
    return (newData.data != null && oldData.data == null) ||
        newData.data != oldData.data;
  }
}
