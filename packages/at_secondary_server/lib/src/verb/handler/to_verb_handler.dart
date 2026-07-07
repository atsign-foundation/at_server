import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/to.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Handler for the cross-server `to:@x` verb.
///
/// Always understood: understanding `to:` is safe (unauthenticated, serves
/// only data that is already publicly readable via `lookup:`), and inbound
/// support being unconditional is what lets outbound emission of `to:` be
/// enabled later without a flag-flip ordering problem. A peer atServer
/// declares the target tenant with `to:@x` and receives that tenant's
/// `{publickey, signing_publickey}` envelope in one round trip (saving the peer
/// a separate `lookup:publickey@x`). Each envelope value is in exactly the
/// `{key, data, metaData}` shape of a `lookup:all:`/`llookup:all:` response,
/// so the peer caches the value with its metadata preserved.
///
/// Single-tenant Dart hosts exactly one atSign, so `@x` must equal this server's
/// own atSign (a multi-tenant endpoint would instead resolve which of its
/// tenants `@x` is).
class ToVerbHandler extends AbstractVerbHandler {
  static To toVerb = To();

  ToVerbHandler(super.keyStore);

  @override
  bool accept(String command) => command.startsWith('to:');

  @override
  Verb getVerb() => toVerb;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
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
    var encPublicKey = await _lookupAllOrNull(
        '${AtConstants.atEncryptionPublicKey}$currentAtSign');
    var signingPublicKey = await _lookupAllOrNull(
        '${AtConstants.atSigningPublicKey}$currentAtSign');

    response.data = jsonEncode({
      'publickey': encPublicKey,
      'signing_publickey': signingPublicKey,
    });
  }

  /// Fetches [key] and returns it in the `{key, data, metaData}` shape of a
  /// `lookup:all:`/`llookup:all:` response, via the same
  /// [SecondaryUtil.prepareResponseData] those handlers use — so the two
  /// formats cannot drift apart. Returns null when the key does not exist.
  Future<Map?> _lookupAllOrNull(String key) async {
    AtData? atData;
    try {
      atData = await keyStore.get(key);
    } on KeyNotFoundException {
      return null;
    }
    var json = SecondaryUtil.prepareResponseData('all', atData, key: key);
    return json == null ? null : jsonDecode(json) as Map;
  }
}
