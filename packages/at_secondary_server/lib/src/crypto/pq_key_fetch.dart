import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/crypto/pq_constants.dart';
import 'package:at_utils/at_logger.dart';

final _log = AtSignLogger('PqKeyFetch');
final _dataPrefix = RegExp('^data:');
final _dummyInboundConnection = DummyInboundConnection();

/// Opens an unauthenticated outbound connection to [fromAtSign] via [ocm]
/// and live-fetches its published PQ cert for the current handshake (not
/// cached). Returns null if the peer publishes no PQ cert or the connection
/// fails.
///
/// The result is used for the current handshake only — it is never cached.
/// Every handshake live-fetches fresh key material so a peer's key rotation
/// is always honoured and there is no stale-cert failure mode.
///
/// Never throws — failures are logged and surface as null.
Future<String?> fetchPeerPqCert(
    OutboundClientManager ocm, String fromAtSign) async {
  try {
    final oc = await ocm.getClient(fromAtSign, _dummyInboundConnection,
        handshakeRequired: false);
    if (!oc.isConnectionCreated) {
      await oc.connect();
    }
    // plookup's wire key is bare (entity+atSign) — the verb handler on the
    // remote side prepends 'public:' itself. pqXwingCertName() returns the
    // public:-prefixed *storage* name used for keyStore.put/get, which is
    // the wrong shape here.
    return (await oc.plookUp('$pqXwingCertNamePart$fromAtSign'))
        ?.replaceFirst(_dataPrefix, '');
  } catch (e) {
    _log.finer('Live PQ cert fetch failed for $fromAtSign: $e');
    return null;
  }
}
