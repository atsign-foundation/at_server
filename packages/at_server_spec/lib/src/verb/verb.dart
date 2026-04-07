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
  Verb? dependsOn();

  /// Returns whether a verb requires authentication
  bool requiresAuth();
}

enum AtVerb {
  // Authenticated
  update(requiresAuth: true),
  llookup(requiresAuth: true),
  plookup(requiresAuth: true),
  delete(requiresAuth: true),
  sync(requiresAuth: true),
  notify(requiresAuth: true, hasSubcommands: true),
  monitor(requiresAuth: true),
  otp(requiresAuth: true),
  keys(requiresAuth: true, hasSubcommands: true),
  batch(requiresAuth: true),
  stats(requiresAuth: true),
  config(requiresAuth: true),

  // Unauthenticated
  from(requiresAuth: false),
  cram(requiresAuth: false),
  pkam(requiresAuth: false),
  pol(requiresAuth: false),
  scan(requiresAuth: false),
  lookup(requiresAuth: false),
  info(requiresAuth: false),
  noop(requiresAuth: false),

  // available both ways, must parse subcommands
  enroll(requiresAuth: false, hasSubcommands: true);

  const AtVerb({required this.requiresAuth, this.hasSubcommands = false});
  final bool requiresAuth;
  final bool hasSubcommands;

  static AtVerb? tryParse(String value) =>
      AtVerb.values.where((v) => v.name == value).firstOrNull;
}

// all subcommands typically require authentication
// there is some overlap in subcommands
enum Subcommand {
  //enroll
  request(requiresAuth: false),
  approve,
  deny,
  revoke,
  unrevoke,
  delete,
  list,
  fetch,
  //notify
  remove,
  status(requiresAuth: false),
  update,
  all,
  //keys
  put,
  get;

  const Subcommand({this.requiresAuth = true});
  final bool requiresAuth;

  static Subcommand? tryParse(String value) =>
      Subcommand.values.where((v) => v.name == value).firstOrNull;
}
