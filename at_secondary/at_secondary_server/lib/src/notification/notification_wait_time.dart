class NotificationWaitTime {
  int _totalPriorities = 0;
  int _prioritiesSum = 0;
  DateTime _lastComputedAt;
  double _waitTime = 0;

  int get totalPriorities => _totalPriorities;

  int get prioritiesSum => _prioritiesSum;

  DateTime get lastComputedAt => _lastComputedAt;

  double get waitTime => _waitTime;

  set totalPriorities(int value) {
    _totalPriorities += value;
  }

  set waitTime(double value) {
    _waitTime = value;
  }

  set lastComputedAt(DateTime value) {
    _lastComputedAt = value;
  }

  set prioritiesSum(int value) {
    _prioritiesSum += value;
  }

  double _calculateMeanWaitTime(DateTime dateTime) {
    // For the first time, set _last_computed value to current time.
    double meanWaitTime;
    if (totalPriorities == 1) {
      _lastComputedAt = dateTime;
      meanWaitTime = DateTime.now().difference(dateTime).inSeconds.toDouble();
      return meanWaitTime;
    } else {
      var difference = DateTime.now().difference(_lastComputedAt).inSeconds;
      meanWaitTime =
          (_waitTime + difference * (totalPriorities - 1)) / totalPriorities;
      _lastComputedAt = DateTime.now();
      return meanWaitTime;
    }
  }

  double calculateWaitTime({DateTime dateTime}) {
    //@sign to pick = Max(sum(priorities) + (Mean (wait time) * Mean of the priorities)
    var meanOfPriorities = _prioritiesSum / _totalPriorities;
    var meanValue = (_calculateMeanWaitTime(dateTime) * meanOfPriorities);
    _waitTime = _prioritiesSum + meanValue;
    return _waitTime;
  }
}
