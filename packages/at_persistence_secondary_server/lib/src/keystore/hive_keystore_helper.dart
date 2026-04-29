import 'package:at_persistence_secondary_server/src/model/at_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_metadata_builder.dart';
import 'package:at_utf7/at_utf7.dart';

/// Pure utility functions used by the Hive-backed keystore. The
/// class is stateless and exposes its operations as static methods;
/// it should never be instantiated.
class HiveKeyStoreHelper {
  // Don't instantiate.
  HiveKeyStoreHelper._();

  /// Normalises a raw atKey into the form actually stored on disk:
  /// trimmed, lowercased, whitespace-stripped, then utf7-encoded.
  static String prepareKey(String key) {
    key = key.trim().toLowerCase().replaceAll(' ', '');
    return Utf7.encode(key);
  }

  /// Builds the [AtData] that should land in the keystore for an
  /// `update`-style operation, merging the new payload with any
  /// existing metadata.
  static AtData prepareDataForKeystoreOperation(AtData newAtData,
      {AtData? existingAtData, required String atSign}) {
    var atData = AtData();
    atData.data = newAtData.data;
    atData.metaData = AtMetadataBuilder(
      atSign: atSign,
      newAtMetaData: newAtData.metaData,
      existingMetaData: existingAtData?.metaData,
    ).build();
    return atData;
  }
}
