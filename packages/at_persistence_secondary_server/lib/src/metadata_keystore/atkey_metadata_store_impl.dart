import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_persistence_secondary_server/src/metadata_keystore/atkey_server_metadata.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

class AtKeyServerMetadataStoreImpl
    with HiveBase<AtKeyMetadata>
    implements AtKeyMetadataStore<String, AtKeyMetadata> {
  late String _boxName;
  String currentAtSign;
  late LazyBox<AtKeyMetadata> box;

  AtKeyServerMetadataStoreImpl(this.currentAtSign);

  @override
  Future<void> initialize() async {
    _boxName =
        'at_key_metadata_store_${AtUtils.getShaForAtSign(currentAtSign)}';
    if (!Hive.isAdapterRegistered(AtKeyServerMetadataAdapter().typeId)) {
      Hive.registerAdapter(AtKeyServerMetadataAdapter());
    }
    box = await Hive.openLazyBox<AtKeyMetadata>(_boxName);
  }

  @override
  Future<AtKeyMetadata?> get(String atKey) async {
    return box.get(atKey);
  }

  @override
  Future<void> put(String atKey, AtKeyMetadata atKeyMetadata) async {
    await box.put(atKey, atKeyMetadata);
  }

  @override
  bool contains(String atKey) {
    return box.containsKey(atKey);
  }

  Future<void> loadDataIntoKeystore(List<CommitEntry> commitEntryList) async {
    for (CommitEntry commitEntry in commitEntryList) {
      // For local keys and keys that are synced to the client, will have
      // commitId "-1". We need not maintain the latestCommitId for such keys.
      if (commitEntry.commitId == -1) {
        continue;
      }
      await box.put(commitEntry.atKey!,
          AtKeyServerMetadata()..commitId = commitEntry.commitId!);
    }
    // After completion, insert a dummy key to ensure the metadata keystore
    // is prepopulated with the existing data and prevent loading data on
    // subsequent restarts
    await box.put(
        'existing_data_populated', AtKeyServerMetadata()..commitId = 1);
  }

  @visibleForTesting
  @override
  BoxBase getBox() {
    return box;
  }
}
