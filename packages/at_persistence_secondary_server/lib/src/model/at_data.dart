import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:hive/hive.dart';
import 'package:at_utf7/at_utf7.dart';

class AtData extends HiveObject {
  String? data;

  AtMetaData? metaData;

  @override
  String toString() {
    return 'AtData{key:$key, data: $data, metaData: ${metaData.toString()}';
  }

  Map toJson() {
    Map map = {};
    // If this AtData has been constructed from json there is no 'key' in the AtData object, since
    // [fromJson] does not set a key (indeed, it cannot set a key as HiveObject doesn't allow that).
    // So we do a null check here to ensure we don't cause Utf7.decode to throw an exception
    if (key != null) {
      map['key'] = Utf7.decode(key);
    }
    map['data'] = data;
    map['metaData'] = metaData!.toJson();
    return map;
  }

  AtData fromJson(Map json) {
    data = json['data'];
    metaData = AtMetaData().fromJson(json['metaData']);
    return this;
  }
}
