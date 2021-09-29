import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/sync_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class SyncFromVerbHandler extends SyncVerbHandler {
  static SyncFrom syncFrom = SyncFrom();

  SyncFromVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  @override
  bool accept(String command) => false;
      // command.startsWith(getName(VerbEnum.sync) + ':') &&
      // command.startsWith('sync:from');

  @override
  Verb getVerb() {
    return syncFrom;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection? atConnection) async {
    var atCommitLog = await (AtCommitLogManagerImpl.getInstance()
        .getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    var fromCommitSequence = int.parse(verbParams[AT_FROM_COMMIT_SEQUENCE]!);
    // sync commitId starts from 0, hence sync entries will be one extra to limit number.
    // to match sync entries to limit number subtract 1 from limit
    var limit = int.parse(verbParams['limit']!) - 1;
    var syncEntriesMap = {};

    // Iterates to get the entries from commit log.
    // Loop ends when any of the following conditions met
    // 1. hive box does not have keys to return
    // 2. commit entries list reaches the limit.
    // 3. hive box does not have keys less than the limit, returns all the keys.
    await Future.doWhile(() async {
      var itr = await _process(
          atCommitLog, fromCommitSequence, verbParams['regex'], limit);
      itr.forEach((entry) {
        syncEntriesMap[entry['atKey']] = entry;
        if (fromCommitSequence < entry['commitId']) {
          fromCommitSequence = entry['commitId'];
        }
      });
      limit = (int.parse(verbParams['limit']!) - 1) - syncEntriesMap.length;
      return itr.isNotEmpty &&
          limit < atCommitLog!.entriesCount() &&
          syncEntriesMap.length < (int.parse(verbParams['limit']!) - 1);
    });
    // Sort the syncEntriesMap on commitId's in descending order.
    var sortedList = syncEntriesMap.values.toList()
      ..sort((c1, c2) => c1['commitId'].compareTo(c2['commitId']));
    response.data = jsonEncode(sortedList);
  }

  Future<Iterable<dynamic>> _process(
      atCommitLog, int fromCommitSequence, String? regex, int limit) async {
    var syncResultList = [];
    var commit_changes =
        atCommitLog?.getChanges(fromCommitSequence, regex, limit: limit);

    commit_changes?.removeWhere((entry) =>
        entry.atKey!.startsWith('privatekey:') ||
        entry.atKey!.startsWith('private:'));

    var distinctKeys = <String>{};
    //sort log by commitId descending
    commit_changes?.sort((CommitEntry entry1, CommitEntry entry2) =>
        sort(entry1.commitId, entry2.commitId));
    // Remove the entries with commit id is null.
    commit_changes?.removeWhere((element) {
      if (element.commitId == null) {
        logger.severe(
            '${element.atKey} commitId is null. Ignoring the commit entry');
        return true;
      }
      return false;
    });
    // for each latest key entry in commit log, get the value
    if (commit_changes != null) {
      await Future.forEach(commit_changes,
          (dynamic entry) => processEntry(entry, distinctKeys, syncResultList));
    }
    Iterable itr = syncResultList;
    return itr;
  }
}
