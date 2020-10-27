///
/// Represents a Verb in the @sign protocol.
///
abstract class Verb {
  /// Returns name of the verb
  String name();

  /// Returns syntax of the verb in a regular expression format
  String syntax();

  /// Returns a sample usage of the Verb
  String usage();

  /// Returns name of the Verb this verb depends on
  Verb dependsOn();

  /// Returns whether a verb requires authentication
  bool requiresAuth();
}
