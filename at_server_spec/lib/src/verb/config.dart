import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';
import 'verb.dart';

/// The “config” verb is used for configuring or viewing an @sign’s block/allow list.
///‘from’ verb functionality is determined by using the configurations of ‘config’ verb.
///If an atsign is in block list, secondary server won’t allow it for authentication.
/// The @sign should be authenticated using cram/pkam verb prior to use the 'config' verb.
/// **configuration syntax**: block:[add/remove]:[@sign list].
/// **view syntax**: block:show.
/// ```
/// e.g.
///   1. config:block:add:@alice @bob //adds @alice, @bob into block list.
///   2. config:block:remove:@alice //removes @alice from block list.
///   3. config:block:show //displays block list @signs.
/// ```
/// Config:set can be used to dynamically modify a limited number of server configurations.
/// testingMode in server config.yaml has to be set to true for this to work.
/// Syntax to use this feature is provided below:
/// **set** - config:set:inbound_max_limit=2
/// **reset/print** - config:reset:inbound_max_limit \ config:print:inbound_max_limit
class Config extends Verb {
  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String name() => 'config';

  @override
  bool requiresAuth() {
    return true;
  }

  @override
  String syntax() => VerbSyntax.config;

  @override
  String usage() {
    return 'configure block syntax config:block:<action>:@<atSign> \n e.g config:block:add:@alice \n view syntax config:show:<type> \n e.g config:shoe:allow \n configure set syntax config:set:<configName>=<configValue> \n config:reset(or)print:<configName>';
  }
}
