/// A dual-write persistence layer: serve reads from a primary backend while
/// mirroring every write byte-exactly into a secondary backend. Run a real
/// workload once (e.g. the functional pack) and compare the two resulting DB
/// sets for logical identity afterwards.
library;

export 'package:at_persistence_secondary_server/src/dual/dual_write_persistence.dart';
