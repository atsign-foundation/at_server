class NotificationWaitTime {
  int totalPriorities = 0;
  int prioritiesSum = 0;
  DateTime lastComputedAt;
  double waitTime = 0;

  /// Returns the mean of wait time.
  double _calculateMeanWaitTime(DateTime dateTime) {
    // For the first time, set _last_computed value to current time.
    double meanWaitTime;
    if (totalPriorities == 1) {
      lastComputedAt = dateTime;
      meanWaitTime = DateTime.now().difference(dateTime).inSeconds.toDouble();
      return meanWaitTime;
    } else {
      var difference = DateTime.now().difference(lastComputedAt).inSeconds;
      meanWaitTime =
          (waitTime + difference * (totalPriorities - 1)) / totalPriorities;
      lastComputedAt = DateTime.now();
      return meanWaitTime;
    }
  }

  /// Calculates the wait time an atSign
  double calculateWaitTime({DateTime dateTime}) {
    //@sign to pick = Max(sum(priorities) + (Mean (wait time) * Mean of the priorities)
    var meanOfPriorities = prioritiesSum / totalPriorities;
    var meanValue = (_calculateMeanWaitTime(dateTime) * meanOfPriorities);
    waitTime = prioritiesSum + meanValue;
    return waitTime;
  }
}
