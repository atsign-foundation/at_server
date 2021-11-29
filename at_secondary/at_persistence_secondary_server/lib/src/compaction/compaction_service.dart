import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

abstract class CompactionService {
  /// Inform the change to CompactionService.
  void informChange(CommitEntry commitEntry);

  /// Compact the keys when ready for compaction.
  void compact();
}
