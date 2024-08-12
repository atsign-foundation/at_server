import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utf7/at_utf7.dart';

class HiveKeyStoreHelper {
  static final HiveKeyStoreHelper _singleton = HiveKeyStoreHelper._internal();

  HiveKeyStoreHelper._internal();

  factory HiveKeyStoreHelper.getInstance() {
    return _singleton;
  }

  String prepareKey(String key) {
    key = key.trim().toLowerCase().replaceAll(' ', '');
    return Utf7.encode(key);
  }

  /// Sets [newMetaData] in AtData object if passed, otherwise sets [newMetaData.metaData]
  AtData prepareDataForKeystoreOperation(AtData newAtData,
      {AtData? existingAtData, AtMetaData? newMetaData, String? atSign}) {
    var atData = AtData();
    atData.data = newAtData.data;
    AtMetaData? metaDataToUpdate;
    newMetaData ?? newAtData.metaData;
    // 1. Use passed metadata
    metaDataToUpdate = newMetaData;

    // 2. Use metadata from passed value if 1 is null
    metaDataToUpdate ??= newAtData.metaData;

    // 3. Use metadata from fetched data if 1 and 2 are null
    metaDataToUpdate ??= existingAtData?.metaData;
    atData.metaData = metaDataToUpdate;
    // set createdBy and updatedBy
    atData.metaData?.createdBy ??= atSign;
    atData.metaData?.updatedBy = atSign;
    // set derived fields
    if (atData.metaData?.ttl != null) {
      atData.metaData?.expiresAt = _getExpiresAt(
          DateTime.now().toUtcMillisecondsPrecision().millisecondsSinceEpoch,
          atData.metaData!.ttl!,
          ttb: atData.metaData?.ttb);
    }
    if (atData.metaData?.ttb != null) {
      atData.metaData?.availableAt = _getAvailableAt(
          DateTime.now().toUtcMillisecondsPrecision().millisecondsSinceEpoch,
          atData.metaData!.ttb!);
    }
    if (atData.metaData?.ttr != null) {
      atData.metaData?.refreshAt = _getRefreshAt(
          DateTime.now().toUtcMillisecondsPrecision(), atData.metaData!.ttr!);
    }

    return atData;
  }

  DateTime? _getAvailableAt(int epochNow, int ttb) =>
      DateTime.fromMillisecondsSinceEpoch(epochNow + ttb).toUtc();

  DateTime? _getExpiresAt(int epochNow, int ttl, {int? ttb}) {
    if (ttl == 0 || ttl == -1) {
      return null; // Key will not expire if TTL is 0 or -1
    }
    var expiresAt = epochNow + ttl + (ttb ?? 0);
    return DateTime.fromMillisecondsSinceEpoch(expiresAt).toUtc();
  }

  DateTime? _getRefreshAt(DateTime today, int ttr) =>
      ttr == -1 ? null : today.add(Duration(seconds: ttr));
}
