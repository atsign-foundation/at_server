abstract class PersistenceManager {

  Future<bool> init({String atSign, String storagePath});

  void scheduleKeyExpireTask(int runFrequencyMins);

  void close();
}