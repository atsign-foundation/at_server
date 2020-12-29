import 'dart:collection';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'dart:convert';

class SyncVerbHandler extends AbstractVerbHandler {
  static Sync sync = Sync();

  SyncVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.sync) + ':');

  @override
  Verb getVerb() {
    return sync;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    var commit_sequence = verbParams[AT_FROM_COMMIT_SEQUENCE];
    var commit_changes =
        AtCommitLog.getInstance().getChanges(int.parse(commit_sequence));
    logger.finer(
        'number of changes since commitId: ${commit_sequence} is ${commit_changes.length}');
    commit_changes.removeWhere((entry) =>
        entry.atKey.startsWith('privatekey:') ||
        entry.atKey.startsWith('private:'));
    var distinctKeys = <String>{};
    var syncResultList = [];
    //sort log by commitId descending
    commit_changes
        .sort((entry1, entry2) => entry2.commitId.compareTo(entry1.commitId));
    // for each latest key entry in commit log, get the value
    await Future.forEach(commit_changes,
        (entry) => _processEntry(entry, distinctKeys, syncResultList));
    logger.finer(
        'number of changes after removing old entries: ${syncResultList.length}');
    //sort the result by commitId ascending
    syncResultList.sort(
        (entry1, entry2) => entry1['commitId'].compareTo(entry2['commitId']));
    var result;

    if (syncResultList.isNotEmpty) {
      result = jsonEncode(syncResultList);
    }

    response.data = result;
    return;
  }

  Future<void> _processEntry(entry, distinctKeys, syncResultList) async {
    var isKeyLatest = distinctKeys.add(entry.atKey);
    var resultMap = entry.toJson();
    // update value only for latest entry for duplicate keys in the commit log
    if (isKeyLatest) {
      var value = await keyStore.get(entry.atKey);
      if (entry.operation == CommitOp.UPDATE) {
        resultMap.putIfAbsent('value', () => value?.data);
      } else if (entry.operation == CommitOp.UPDATE_ALL ||
          entry.operation == CommitOp.UPDATE_META) {
        resultMap.putIfAbsent('value', () => value?.data);
        _populateMetadata(value, resultMap);
      }
      syncResultList.add(resultMap);
    }
  }

  void _populateMetadata(value, resultMap) {
    var metaDataMap = <String, dynamic>{};
    AtMetaData metaData = value?.metaData;
    if (metaData != null) {
      if (metaData.ttl != null) {
        metaDataMap.putIfAbsent(AT_TTL, () => metaData.ttl.toString());
      }
      if (metaData.ttb != null) {
        metaDataMap.putIfAbsent(AT_TTB, () => metaData.ttb.toString());
      }
      if (metaData.ttr != null) {
        metaDataMap.putIfAbsent(AT_TTR, () => metaData.ttr.toString());
      }
      if (metaData.isCascade != null) {
        metaDataMap.putIfAbsent(CCD, () => metaData.isCascade.toString());
      }
      if (metaData.isBinary != null) {
        metaDataMap.putIfAbsent(IS_BINARY, () => metaData.isBinary.toString());
      }
      if (metaData.isEncrypted != null) {
        metaDataMap.putIfAbsent(
            IS_ENCRYPTED, () => metaData.isEncrypted.toString());
      }
      resultMap.putIfAbsent('metadata', () => metaDataMap);
    }
  }
}
