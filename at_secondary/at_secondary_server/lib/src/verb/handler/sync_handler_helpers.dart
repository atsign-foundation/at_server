import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

Map populateMetadata(value) {
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
    if (metaData.sharedKeyEnc != null) {
      metaDataMap.putIfAbsent(
          SHARED_KEY_ENCRYPTED, () => metaData.sharedKeyEnc);
    }
    if (metaData.pubKeyCS != null) {
      metaDataMap.putIfAbsent(
          SHARED_WITH_PUBLIC_KEY_CHECK_SUM, () => metaData.pubKeyCS);
    }
  }
  return metaDataMap;
}

/// Class to represents the sync entry.
class KeyStoreEntry {
  late String atKey;
  String? value;
  Map? atMetaData;
  late int commitId;
  late CommitOp operation;

  @override
  String toString() {
    return 'atKey: $atKey, value: $value, metadata: $atMetaData, commitId: $commitId, operation: $operation';
  }

  Map toJson() {
    var map = {};
    map['atKey'] = atKey;
    map['value'] = value;
    map['metadata'] = atMetaData;
    map['commitId'] = commitId;
    map['operation'] = operation.name;
    return map;
  }

  KeyStoreEntry fromJson(Map json) {
    atKey = json['atKey'];
    value = json['value'];
    atMetaData = json['metadata'];
    commitId = json['commitId'];
    operation = json['operation'];
    return this;
  }
}
