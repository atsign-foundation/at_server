import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utf7/at_utf7.dart';

class AtData {
  String? data;

  AtMetaData? metaData;

  /// The box key this AtData was read under, or `null` for an
  /// instance that was not loaded from storage (e.g. one built via
  /// [fromJson]). Transient — the keystore sets it on read; it is
  /// not part of the serialized form.
  String? key;

  @override
  String toString() {
    return 'AtData{key:$key, data: $data, metaData: ${metaData.toString()}';
  }

  Map toJson() {
    Map map = {};
    // `key` is null for an AtData constructed via [fromJson] rather
    // than loaded from storage; skip it so Utf7.decode isn't handed
    // a null.
    final k = key;
    if (k != null) {
      map['key'] = Utf7.decode(k);
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
