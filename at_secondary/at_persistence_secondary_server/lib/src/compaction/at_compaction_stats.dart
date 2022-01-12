///base class for compaction statistics
abstract class AtCompactionStats{

  ///measurement of parameters before compaction job is run(time, log size, no. of keys)
  void preCompaction();

  ///calculation of compaction attributes (duration, keys deleted, etc) by comparison with preCompaction parameters
  ///writes compaction statistics into keystore
  Future <void> postCompaction();

}