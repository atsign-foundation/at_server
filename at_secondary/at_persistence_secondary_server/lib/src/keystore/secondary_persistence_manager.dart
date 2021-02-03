abstract class PersistenceManager {
  Future<bool> init(String atSign, {String storagePath});

  void scheduleKeyExpireTask(int runFrequencyMins);

  Future<dynamic> openVault(String atsign, {List<int> hiveSecret});

  void close();
}
