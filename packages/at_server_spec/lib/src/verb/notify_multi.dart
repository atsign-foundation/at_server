import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/src/verb/verb.dart';

/// The "notify:multi" verb notifies several atSigns of one key, with one value
/// and the metadata each recipient needs to read it.
///
/// Every recipient gets the same value, so it suits a value encrypted once
/// under a key all of them hold. The metadata fields that describe one
/// recipient's copy (`sharedKeyEnc`, `pubKeyCS`, `pubKeyHash`,
/// `skeEncKeyName`, `skeEncAlgo`) are refused, as are those the atServer does
/// not deliver (`isBinary`, `encoding`, `sharedKeyStatus`, `dataSignature`),
/// and `ttr` and `ccd`: no recipient keeps a cached copy. `eAtn` and `eph`
/// work as on `notify`. An atServer that supports this verb lists the
/// feature `notify.multi` in its `info` response.
///
/// **Syntax**:
/// notify:multi[:update|:delete][:ttln:<ms>|:eAtn:<ISO-8601 UTC>][:eph][<metadata>]:<@recipient>[,<@recipient>...]:<key>@<sender>[:<value>]
///
/// Example:
/// notify:multi:update:ttln:900000:isEncrypted:true:@bob,@colin:msg.chat.myapp@alice:<ciphertext>
class NotifyMulti extends Verb {
  @override
  String name() => 'notifyMulti';

  @override
  String syntax() => VerbSyntax.notifyMulti;

  @override
  Verb? dependsOn() {
    return null;
  }

  @override
  String usage() {
    return 'e.g. notify:multi:@bob,@colin:msg.chat.myapp@alice:<value>';
  }

  @override
  bool requiresAuth() {
    return true;
  }
}
