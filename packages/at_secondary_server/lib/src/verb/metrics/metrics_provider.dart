import 'package:at_secondary/src/server/at_secondary_impl.dart';

abstract class MetricProvider {
  AtSecondaryServerImpl atServer;

  MetricProvider(this.atServer);

  String getName();

  dynamic getMetrics({String? regex});
}
