abstract class PersistenceManager {
  Future<bool> init(String atSign, String storagePath, {String password});
  void scheduleKeyExpireTask(int runFrequencyMins);
  void close();
}
