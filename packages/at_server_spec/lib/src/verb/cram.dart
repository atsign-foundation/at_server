import 'package:at_server_spec/src/verb/from.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_commons/at_commons.dart';

/// The cram verb is used to authenticate the @sign to the secondary server. On successful request, binds the @sign to the secondary server. The secret is appended to the challenge (response of from verb) and gives a SHA512 digest which serves as an input to the CRAM verb.
/// On successful cram verb request, the @sign is successfully authenticated to the secondary server and allows user to Add/Update, Delete and lookup the keys in their respective secondary servers.
/// We use “cram” authentication for the first time and will create a public/private key pair for pkam authentication for subsequent logins.
/// A malformed request closes the @sign client connection.
///Syntax: cram:<digest>
class Cram extends Verb {
  @override
  String name() => 'cram';

  @override
  String syntax() => VerbSyntax.cram;

  @override
  Verb dependsOn() {
    return From();
  }

  @override
  String usage() {
    return 'cram:<digest>';
  }

  @override
  bool requiresAuth() {
    return false;
  }
}
