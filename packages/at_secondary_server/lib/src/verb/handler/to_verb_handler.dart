import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/to.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Handler for the cross-server `to:@x` verb.
///
/// Flag-gated: [accept] returns false when
/// [AtSecondaryConfig.crossServerToVerbEnabled] is off, so `to:` is simply an
/// unknown verb — behaviour is identical to today. When on, a peer atServer
/// declares the target tenant with `to:@x` and receives that tenant's
/// `{publickey, signing_publickey}` envelope in one round trip (saving the peer
/// a separate `lookup:publickey@x`).
///
/// Single-tenant Dart hosts exactly one atSign, so `@x` must equal this server's
/// own atSign (a multi-tenant endpoint would instead resolve which of its
/// tenants `@x` is).
class ToVerbHandler extends AbstractVerbHandler {
  static To toVerb = To();

  ToVerbHandler(super.keyStore);

  @override
  bool accept(String command) =>
      AtSecondaryConfig.crossServerToVerbEnabled && command.startsWith('to:');

  @override
  Verb getVerb() => toVerb;

  @override
  Future<void> processVerb(Response response,
      HashMap<String, String?> verbParams, InboundConnection atConnection) async {
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    Atsign target = verbParams[AtConstants.atSign]!.toAtsign();

    if (target != currentAtSign) {
      throw SecondaryNotFoundException(
          '$target is not hosted on this atServer');
    }

    // Record the tenant the peer is operating on — informational in the
    // single-tenant model.
    (atConnection.metaData as InboundConnectionMetadata).toAtSign = target;

    // The signing public key is generated at server startup so it is present;
    // the encryption public key may be absent until the atSign onboards one.
    var encPublicKey =
        await _getOrNull('${AtConstants.atEncryptionPublicKey}$currentAtSign');
    var signingPublicKey =
        await _getOrNull('${AtConstants.atSigningPublicKey}$currentAtSign');

    response.data = jsonEncode({
      'publickey': encPublicKey,
      'signing_publickey': signingPublicKey,
    });
  }

  Future<String?> _getOrNull(String key) async {
    try {
      return (await keyStore.get(key))?.data;
    } on KeyNotFoundException {
      return null;
    }
  }
}
