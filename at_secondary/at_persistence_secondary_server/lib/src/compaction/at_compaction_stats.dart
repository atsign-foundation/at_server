abstract class AtCompactionStats{

  void initializeStats();

  void calculateStats();

  Future <void> writeStats(AtCompactionStats atCompactionStats);

}