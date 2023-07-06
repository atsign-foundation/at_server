import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

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
    throw UnimplementedError();
  }
}
