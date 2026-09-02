import 'package:at_persistence_secondary_server/src/spec/keystore/at_asserted_timestamps.dart';
import 'package:at_persistence_secondary_server/src/spec/keystore/at_key_canonicalisation.dart';
import 'package:at_persistence_secondary_server/src/spec/keystore/at_data.dart';
import 'package:at_persistence_secondary_server/src/spec/keystore/at_metadata_builder.dart';
import 'package:at_utf7/at_utf7.dart';

/// Pure utility functions used by the Hive-backed keystore. The
/// class is stateless and exposes its operations as static methods;
/// it should never be instantiated.
class HiveKeyStoreHelper {
  // Don't instantiate.
  HiveKeyStoreHelper._();

  /// Normalises a raw atKey into the form actually stored on disk:
  /// [canonicalAtKey], then utf7-encoded.
  ///
  /// The fold itself lives in [canonicalAtKey] rather than here because
  /// callers above the keystore have to reproduce it exactly — a key they
  /// build, or an id they compare against one an enumeration returned, is
  /// about a different string from the one on disk otherwise. Two spellings
  /// of one fold can disagree with nothing going red, since a non-canonical
  /// key still resolves; one definition is what removes that.
  static String prepareKey(String key) => Utf7.encode(canonicalAtKey(key));

  /// Builds the [AtData] that should land in the keystore for an
  /// `update`-style operation, merging the new payload with any
  /// existing metadata. [asserted] carries caller-asserted
  /// timestamps for the builder (see [AtAssertedTimestamps]).
  static AtData prepareDataForKeystoreOperation(AtData newAtData,
      {AtData? existingAtData,
      required String atSign,
      AtAssertedTimestamps? asserted}) {
    var atData = AtData();
    atData.data = newAtData.data;
    atData.metaData = AtMetadataBuilder(
      atSign: atSign,
      newAtMetaData: newAtData.metaData,
      existingMetaData: existingAtData?.metaData,
      asserted: asserted,
    ).build();
    return atData;
  }
}
