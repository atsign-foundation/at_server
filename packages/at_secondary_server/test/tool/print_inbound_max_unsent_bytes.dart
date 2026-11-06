import 'package:at_secondary/src/server/at_secondary_config.dart';

/// Prints the unsent-bytes limit this process's environment and config give.
void main() => print(AtSecondaryConfig.inbound_max_unsent_bytes);
