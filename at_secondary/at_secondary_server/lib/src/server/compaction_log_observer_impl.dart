import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_utils/at_logger.dart';

abstract class AtCompactionLogObserverImpl implements AtCompactionLogObserver {
  late AtLogType atLogType;

  var keyStore = SecondaryPersistenceStoreFactory.getInstance()
      .getSecondaryPersistenceStore(
          AtSecondaryServerImpl.getInstance().currentAtSign)!
      .getSecondaryKeyStore();

  final _logger = AtSignLogger('AtCompactionLogObserverImpl');

  @override
  Future<void> informChange(int keysCompacted) async {
    _logger.info(
        '${atLogType.runtimeType} compaction completed. $keysCompacted keys compacted.');

    var compactionStats = CompactionStats()
      ..previousRun = DateTime.now().toUtc()
      ..keysCompacted = keysCompacted;

    await keyStore!
        .put(_getKey(), AtData()..data = jsonEncode(compactionStats));
  }

  String _getKey() {
    if (atLogType is AtCommitLog) {
      return commitLogCompactionKey;
    }
    if (atLogType is AtAccessLog) {
      return accessLogCompactionKey;
    }
    return '';
  }
}

class CommitLogCompactionObserver extends AtCompactionLogObserverImpl {
  CommitLogCompactionObserver(atLogType) {
    super.atLogType = atLogType;
    atLogType.attachObserver(this);
  }
}

class AccessLogCompactionObserver extends AtCompactionLogObserverImpl {
  AccessLogCompactionObserver(atLogType) {
    super.atLogType = atLogType;
    atLogType.attachObserver(this);
  }
}

/// Class represents the [AtLogType] compaction metrics.
class CompactionStats {
  DateTime? previousRun;
  int keysCompacted = 0;

  Map toJson() =>
      {'previousRun': previousRun.toString(), 'keysCompacted': keysCompacted};

  CompactionStats fromJson(Map json) {
    previousRun = json['previousRun'] != null
        ? DateTime.parse(json['previousRun'])
        : null;
    keysCompacted = json['keysCompacted'];
    return this;
  }
}
