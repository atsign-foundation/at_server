import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class SyncVerbHandler extends AbstractVerbHandler {
  static Sync sync = Sync();

  SyncVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  @override
  bool accept(String command) => false;
      // command.startsWith(getName(VerbEnum.sync) + ':') &&
      // !command.startsWith('sync:from');

  @override
  Verb getVerb() {
    return sync;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection? atConnection) async {
    var commitSequence = verbParams[AT_FROM_COMMIT_SEQUENCE]!;
    var atCommitLog = await (AtCommitLogManagerImpl.getInstance()
        .getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    var regex = verbParams[AT_REGEX];
    var commitChanges =
        await atCommitLog!.getChanges(int.parse(commitSequence), regex);
    logger.finer(
        'number of changes since commitId: $commitSequence is ${commitChanges.length}');
    commitChanges.removeWhere((entry) =>
        entry.atKey!.startsWith('privatekey:') ||
        entry.atKey!.startsWith('private:'));
    if (regex != null && regex != 'null') {
      logger.finer('regex for sync : $regex');
      commitChanges
          .removeWhere((entry) => !isRegexMatches(entry.atKey!, regex));
    }
    var distinctKeys = <String>{};
    var syncResultList = [];
    //sort log by commitId descending
    commitChanges
        .sort((entry1, entry2) => sort(entry1.commitId, entry2.commitId));
    // Remove the entries with commit id is null.
    commitChanges.removeWhere((element) {
      if (element.commitId == null) {
        logger.severe(
            '${element.atKey} commitId is null. Ignoring the commit entry');
        return true;
      }
      return false;
    });
    // for each latest key entry in commit log, get the value
    await Future.forEach(
        commitChanges,
        (CommitEntry entry) =>
            processEntry(entry, distinctKeys, syncResultList));

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

  int sort(commitId1, commitId2) {
    if (commitId1 == null && commitId2 == null) return 0;
    if (commitId1 == null && commitId2 != null) return -1;
    if (commitId1 != null && commitId2 == null) return 1;
    return commitId2.compareTo(commitId1);
  }

  Future<void> processEntry(entry, distinctKeys, syncResultList) async {
    var isKeyLatest = distinctKeys.add(entry.atKey);
    var resultMap = entry.toJson();
    // update value only for latest entry for duplicate keys in the commit log
    if (isKeyLatest) {
      var value = await keyStore!.get(entry.atKey);
      if (entry.operation == CommitOp.UPDATE) {
        resultMap.putIfAbsent('value', () => value?.data);
      } else if (entry.operation == CommitOp.UPDATE_ALL ||
          entry.operation == CommitOp.UPDATE_META) {
        resultMap.putIfAbsent('value', () => value?.data);
        populateMetadata(value, resultMap);
      }
      syncResultList.add(resultMap);
    }
  }

  void logResponse(String response) {
    try {
      var parsedResponse = '';
      final responseJson = jsonDecode(response);
      for (var syncRecord in responseJson) {
        if (syncRecord['metadata'] != null &&
            syncRecord['metadata']['isBinary'] != null &&
            syncRecord['metadata']['isBinary'] == 'true') {
          final newRecord = {};
          newRecord['atKey'] = syncRecord['atKey'];
          newRecord['operation'] = syncRecord['operation'];
          newRecord['commitId'] = syncRecord['commitId'];
          newRecord['metadata'] = syncRecord['metadata'];
          parsedResponse += newRecord.toString();
        } else {
          parsedResponse += syncRecord.toString();
        }
      }
      logger.finer('sync response: $parsedResponse');
    } on Exception catch (e, trace) {
      logger.severe('exception logging sync response: ${e.toString()}');
      logger.severe(trace);
    }
  }

  void populateMetadata(value, resultMap) {
    var metaDataMap = <String, dynamic>{};
    AtMetaData? metaData = value?.metaData;
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

      if (metaData.dataSignature != null) {
        metaDataMap.putIfAbsent(
            PUBLIC_DATA_SIGNATURE, () => metaData.dataSignature.toString());
      }
      if (metaData.isBinary != null) {
        metaDataMap.putIfAbsent(IS_BINARY, () => metaData.isBinary.toString());
      }
      if (metaData.isEncrypted != null) {
        metaDataMap.putIfAbsent(
            IS_ENCRYPTED, () => metaData.isEncrypted.toString());
      }

      if (metaData.createdAt != null) {
        metaDataMap.putIfAbsent(
            CREATED_AT, () => metaData.createdAt.toString());
      }
      if (metaData.updatedAt != null) {
        metaDataMap.putIfAbsent(
            UPDATED_AT, () => metaData.updatedAt.toString());
      }

      resultMap.putIfAbsent('metadata', () => metaDataMap);
    }
  }

  bool isRegexMatches(String atKey, String regex) {
    var result = false;
    if ((RegExp(regex).hasMatch(atKey)) ||
        atKey.contains(AT_ENCRYPTION_SHARED_KEY) ||
        atKey.startsWith('public:') ||
        atKey.contains(AT_PKAM_SIGNATURE) ||
        atKey.contains(AT_SIGNING_PRIVATE_KEY)) {
      result = true;
    }
    return result;
  }
}
