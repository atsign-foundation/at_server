abstract class MetricProvider {
  String getName();
  dynamic getMetrics({String regex});
}
