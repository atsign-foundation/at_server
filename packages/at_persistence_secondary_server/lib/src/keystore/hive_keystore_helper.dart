import 'package:at_persistence_secondary_server/src/model/at_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_metadata_builder.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utf7/at_utf7.dart';

class HiveKeyStoreHelper {
  static final HiveKeyStoreHelper _singleton = HiveKeyStoreHelper._internal();

  HiveKeyStoreHelper._internal();

  factory HiveKeyStoreHelper.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('HiveKeyStoreHelper');

  String prepareKey(String key) {
    key = key.trim().toLowerCase().replaceAll(' ', '');
    return Utf7.encode(key);
  }

  AtData prepareDataForCreate(AtData newData,
      {int? ttl,
      int? ttb,
      int? ttr,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum,
      String? encoding,
      String? atSign}) {
    var atData = AtData();
    atData.data = newData.data;
    atData.metaData = AtMetadataBuilder(
            atSign: atSign,
            newAtMetaData: newData.metaData,
            ttl: ttl,
            ttb: ttb,
            ttr: ttr,
            ccd: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: publicKeyChecksum,
            encoding: encoding)
        .build();

    return atData;
  }

  AtData prepareDataForUpdate(AtData existingData, AtData newData,
      {int? ttl,
      int? ttb,
      int? ttr,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum,
      String? encoding,
      String? atSign}) {
    newData.metaData = AtMetadataBuilder(
            atSign: atSign,
            newAtMetaData: newData.metaData,
            existingMetaData: existingData.metaData,
            ttl: ttl,
            ttb: ttb,
            ttr: ttr,
            ccd: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: publicKeyChecksum,
            encoding: encoding)
        .build();
    return newData;
  }

  static bool hasValueChanged(AtData newData, AtData oldData) {
    return (newData.data != null && oldData.data == null) ||
        newData.data != oldData.data;
  }
}
