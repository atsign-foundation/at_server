import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// Keys verb is specifically used to update security keys to the secondary keystore.
/// e.g. syntax to update default encryption public key
/// keys:put:public:keyName:encryptionPublicKey:namespace:__global:keyType:rsa2048:<encryption_public_key>
/// e.g. syntax to update encryption private key encrypted using apkam public key
/// keys:put:private:keyName:encryptionPrivateKey:namespace:__global:appName:<appName>:appName:<deviceName>:<encryptedEncryptionPrivateKey>
/// e.g. syntax to get all private keys
/// keys:get:public
class Keys extends Verb {
  @override
  String name() => 'keys';

  @override
  String syntax() => VerbSyntax.keys;

  @override
  String usage() {
    return 'e.g. keys:put:public:keyName:encryptionPublicKey:namespace:__global:keyType:rsa2048:<public_key>';
  }

  @override
  bool requiresAuth() {
    return true;
  }

  @override
  Verb? dependsOn() {
    return null;
  }
}
