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

  AtData prepareDataForKeystoreOperation(AtData newAtData,
      {AtData? existingAtData,
      int? ttl,
      int? ttb,
      int? ttr,
      bool? isCascade,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum,
      String? encoding,
      String? encKeyName,
      String? encAlgo,
      String? ivNonce,
      String? skeEncKeyName,
      String? skeEncAlgo,
      String? atSign}) {
    var atData = AtData();
    atData.data = newAtData.data;
    atData.metaData = AtMetadataBuilder(
            atSign: atSign,
            newAtMetaData: newAtData.metaData,
            existingMetaData: existingAtData?.metaData,
            ttl: ttl,
            ttb: ttb,
            ttr: ttr,
            ccd: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: publicKeyChecksum,
            encoding: encoding,
            encKeyName: encKeyName,
            encAlgo: encAlgo,
            ivNonce: ivNonce,
            skeEncKeyName: skeEncKeyName,
            skeEncAlgo: skeEncAlgo)
        .build();
    return atData;
  }
}
