class NotificationWaitTime {
  int _totalPriorities = 0;
  int _prioritiesSum = 0;
  DateTime? _lastComputedAt;
  double _waitTime = 0;

  // ignore: unnecessary_getters_setters
  int get totalPriorities => _totalPriorities;

  // ignore: unnecessary_getters_setters
  int get prioritiesSum => _prioritiesSum;

  // ignore: unnecessary_getters_setters
  DateTime? get lastComputedAt => _lastComputedAt;

  // ignore: unnecessary_getters_setters
  double get waitTime => _waitTime;

  // ignore: unnecessary_getters_setters
  set totalPriorities(int value) {
    _totalPriorities += value;
  }

  // ignore: unnecessary_getters_setters
  set waitTime(double value) {
    _waitTime = value;
  }

  // ignore: unnecessary_getters_setters
  set lastComputedAt(DateTime? value) {
    _lastComputedAt = value;
  }

  // ignore: unnecessary_getters_setters
  set prioritiesSum(int value) {
    _prioritiesSum += value;
  }

  double _calculateMeanWaitTime(DateTime? dateTime) {
    // For the first time, set _last_computed value to current time.
    double meanWaitTime;
    if (totalPriorities == 1) {
      _lastComputedAt = dateTime;
      meanWaitTime = DateTime.now().difference(dateTime!).inSeconds.toDouble();
      return meanWaitTime;
    } else {
      var difference = DateTime.now().difference(_lastComputedAt!).inSeconds;
      meanWaitTime =
          (waitTime + difference * (totalPriorities - 1)) / totalPriorities;
      lastComputedAt = DateTime.now();
      return meanWaitTime;
    }
  }

  double calculateWaitTime({DateTime? dateTime}) {
    //@sign to pick = Max(sum(priorities) + (Mean (wait time) * Mean of the priorities)
    var meanOfPriorities = prioritiesSum / totalPriorities;
    var meanValue = (_calculateMeanWaitTime(dateTime) * meanOfPriorities);
    waitTime = prioritiesSum + meanValue;
    return waitTime;
  }
}
