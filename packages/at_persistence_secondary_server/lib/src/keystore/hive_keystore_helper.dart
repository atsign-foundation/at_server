import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/model/at_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_metadata_builder.dart';
import 'package:at_utf7/at_utf7.dart';

class HiveKeyStoreHelper {
  static final HiveKeyStoreHelper _singleton = HiveKeyStoreHelper._internal();

  HiveKeyStoreHelper._internal();

  factory HiveKeyStoreHelper.getInstance() {
    return _singleton;
  }

  String prepareKey(String key) {
    key = key.trim().toLowerCase().replaceAll(' ', '');
    return Utf7.encode(key);
  }

  AtData prepareDataForKeystoreOperation(AtData newAtData,
      {AtMetaData? existingMetaData, AtMetaData? newMetaData, String? atSign}) {
    var atData = AtData();
    atData.data = newAtData.data;
    atData.metaData = AtMetadataBuilder(
            atSign: atSign,
            newMetaData: newMetaData,
            existingMetaData: existingMetaData)
        .build();
    return atData;
  }
}
