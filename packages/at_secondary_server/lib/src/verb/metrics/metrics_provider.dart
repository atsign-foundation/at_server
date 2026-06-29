/// Base type for the individual server-stats providers built by
/// `StatsVerbHandler.getProvider`. Each implementation declares exactly the
/// collaborator(s) it needs as constructor parameters rather than reaching
/// through a shared god-class handle, so a provider's dependencies are obvious
/// at its construction site.
abstract class MetricProvider {
  String getName();

  dynamic getMetrics({String? regex});
}
