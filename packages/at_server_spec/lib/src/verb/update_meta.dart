import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_commons/at_commons.dart';

/// The update meta verb updates the metadata of the keys in the secondary server. The update meta verb is used to set/update metadata of a key.
/// The @sign should be authenticated using cram verb prior to use the update meta verb.
/// A malformed request closes the @sign client connection.
///
/// ttl - time to live
/// Defines the time after which value should expire
/// Accepts time duration in milliseconds
/// update:meta:@alice:location@bob:ttl:60000 - updates the existing ttl value to 60000 for the location
/// ttb - time to born
/// Defines the time after which value should be displayed
/// Accepts time duration in milliseconds
/// update:meta:@alice:location@bob:ttb:60000 - updates the existing ttb value to 60000 for the location
/// ttr:
/// Creates a cached key at the receiver side.
/// Accepts a time duration in milli seconds which is a positive integer value to refresh the cached key or -1 to cache for forever.
/// update:meta:@alice:location@bob:ttr:60000 - updates the existing ttb value to 60000 for the location
/// cAt / uAt / eAt / aAt:
/// Caller-asserted createdAt / updatedAt / expiresAt / availableAt, as
/// ISO 8601 UTC timestamps, stored faithfully instead of being rederived.
/// An asserted eAt/aAt with no accompanying ttl/ttb also stores the
/// relative it implies. Once set, expiresAt/availableAt move only when a
/// request speaks about that axis (an assertion, a fresh ttl/ttb, ttl:0
/// to clear the expiry, or ttb:0 to re-stamp availableAt to now) —
/// update:meta:@alice:location@bob:uAt:2026-05-05T11:59:44.123456Z
/// nc (no-commit):
/// Performs the metadata update as usual but writes no commit log entry AND
/// removes the key's existing entry; the response is data:-1 —
/// update:meta:nc:@alice:location@bob:ttl:60000
class UpdateMeta extends Verb {
  @override
  Verb dependsOn() => Cram();

  @override
  String name() => 'update:meta';

  @override
  bool requiresAuth() => true;

  @override
  String syntax() => VerbSyntax.update_meta;

  @override
  String usage() => 'update:meta:ttl:20000:ttb:20000:ttr:20000';
}
