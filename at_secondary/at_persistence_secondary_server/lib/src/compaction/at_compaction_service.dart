import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class AtCompactionService {
  static final AtCompactionService _singleton = AtCompactionService._internal();

  AtCompactionService._internal();

  factory AtCompactionService.getInstance() {
    return _singleton;
  }

  late AtCompactionStatsService atCompactionStatsService;
  late AtCompactionStats? atCompactionStats;

  ///[atCompactionConfig] is an object containing compaction configuration/parameters
  ///[atCompaction] specifies which logs the compaction job will run on
  ///Method chooses which type of compaction to be run based on [atCompactionConfig]
  Future<void> executeCompaction(
      AtCompactionConfig atCompactionConfig,
      AtCompaction atCompaction,
      SecondaryPersistenceStore secondaryPersistenceStore) async {
    atCompactionStatsService =
        AtCompactionStatsServiceImpl(atCompaction, secondaryPersistenceStore);
    atCompaction.setCompactionConfig(atCompactionConfig);
    final keysToCompact = await atCompaction.getKeysToDeleteOnCompaction();
    for (String key in keysToCompact) {
      try {
        await atCompaction.deleteKeyForCompaction(key);
      } on Exception catch (e) {
        //# TODO handle
      }
    }
    atCompactionStats = _generateStats(keysToCompact);
    await atCompactionStatsService.handleStats(atCompactionStats);
  }

  AtCompactionStats _generateStats(keysToCompact) {
    //# TODO implement
    return AtCompactionStats();
  }
}
