abstract class MetricProvider {
  String getName();
  Future<dynamic> getMetrics({String regex});
}
