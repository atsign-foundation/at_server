import 'package:at_server_spec/at_verb_spec.dart';

/// The `to:` verb — cross-server, UNAUTHENTICATED, allowed as the first verb.
///
/// A peer atServer sends `to:@x` as the first verb after opening the socket to
/// declare which tenant it is operating against; the server replies with the
/// `{publickey, signing_publickey}` envelope for `@x`. Declaring the target
/// tenant up front gives architectural flexibility for atServer endpoints —
/// e.g. atServers reached through proxies / gateways. Single-tenant Dart:
/// `@x` must be this server's own atSign.
///
/// Defined locally (rather than in at_commons/at_server_spec) so the cross-server
/// verb can land in a single repo behind a flag; the grammar can be promoted
/// upstream later.
///
/// Syntax: `to:@<atSign>`
class To extends Verb {
  @override
  String name() => 'to';

  @override
  String syntax() => r'^to:(?<atSign>@?[^\s:]+)$';

  @override
  Verb? dependsOn() => null;

  @override
  String usage() => 'syntax to:@<atSign> \n e.g to:@alice';

  @override
  bool requiresAuth() => false;
}
