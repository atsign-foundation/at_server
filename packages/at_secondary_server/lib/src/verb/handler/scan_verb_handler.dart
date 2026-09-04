import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/wire_param_names.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

/// Handles `scan`, which returns the keys this connection may look up.
class ScanVerbHandler extends AbstractVerbHandler {
  static Scan scan = Scan();
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;

  ScanVerbHandler(
      super.keyStore, this.outboundClientManager, this.cacheManager);

  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.scan));

  @override
  Verb getVerb() {
    return scan;
  }

  /// Throws [UnAuthenticatedException] when a scan names another atSign, or
  /// asks for the commit log, on an unauthenticated connection.
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var atConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    var forAtSign = verbParams[AtConstants.forAtSign];
    var scanRegex = verbParams[AtConstants.regex];
    var showHiddenKeys =
        verbParams[AtConstants.showHidden] == 'true' ? true : false;

    try {
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      if (verbParams[WireParams.commitLog] != null) {
        // scan:cl scans the commit log instead of the keystore, so a
        // client can inspect (and then delete:nc) its entries.
        if (!atConnectionMetadata.isAuthenticated) {
          throw UnAuthenticatedException(
              'scan:cl requires an authenticated connection');
        }
        if ((forAtSign != null && forAtSign.isNotEmpty) &&
            forAtSign != currentAtSign) {
          // The outbound scan proxy cannot forward :cl, so a remote
          // commit-log scan would silently degrade to a plain remote
          // scan; refuse loudly instead.
          throw InvalidRequestException(
              'scan:cl can only scan this atSign\'s own commit log');
        }
        response.data = jsonEncode(await getCommitLogEntries(
            atConnectionMetadata, scanRegex, showHiddenKeys, currentAtSign));
        return;
      }
      // A forAtSign other than this one asks the far atSign for the keys it
      // has shared with this one.
      if ((forAtSign != null && forAtSign.isNotEmpty) &&
          forAtSign != currentAtSign) {
        if (!atConnectionMetadata.isAuthenticated) {
          throw UnAuthenticatedException(
              'Scan to another atSign cannot be performed without auth');
        }
        response.data =
            await _getExternalKeys(forAtSign, scanRegex, atConnection);
      } else {
        response.data = jsonEncode(await getLocalKeys(
            atConnectionMetadata, scanRegex, showHiddenKeys, currentAtSign));
      }
    } on Exception catch (e) {
      response.isError = true;
      response.errorMessage = e.toString();
      rethrow;
    }
  }

  /// The keys [forAtSign] shares with this atSign, matching [scanRegex],
  /// fetched over an outbound connection. Null when there are none.
  Future<String?> _getExternalKeys(String forAtSign, String? scanRegex,
      InboundConnection atConnection) async {
    final OutboundClient outBoundClient = await outboundClientManager
        .getClient(forAtSign, atConnection, handshakeRequired: true);
    var handShake = false;
    if (!outBoundClient.isHandShakeDone) {
      await outBoundClient.connect();
      handShake = true;
    }
    var scanResult =
        await outBoundClient.scan(handshake: handShake, regex: scanRegex);
    return scanResult;
  }

  /// Filter keys based on authentication type of inbound connection
  @visibleForTesting
  Future<List<String>> getLocalKeys(
      InboundConnectionMetadata atConnectionMetadata,
      String? scanRegex,
      bool showHiddenKeys,
      String currentAtSign) async {
    List<String> localKeysList =
        await (await keyStore.getKeys(regex: scanRegex)).toList();
    if (logger.logger.isLoggable(Level.INFO)) {
      logger.info('${localKeysList.length} local keys for regex $scanRegex');
    } else if (logger.logger.isLoggable(Level.FINER)) {
      logger.finer('${localKeysList.length} local keys for regex $scanRegex'
          ' : $localKeysList');
    }
    if (atConnectionMetadata.isAuthenticated) {
      localKeysList
          .removeWhere((key) => _isPrivateKeyForAtSign(key, showHiddenKeys));
      if (AbstractVerbHandler.isCramConnection(atConnectionMetadata)) {
        return localKeysList;
      }
      if (atConnectionMetadata.enrollmentId == null ||
          atConnectionMetadata.enrollmentId!.isEmpty) {
        // Not CRAM and carrying no enrollment: nothing to filter by, so
        // nothing is visible.
        return <String>[];
      }
      return await _filterKeysBasedOnEnrollmentId(
          atConnectionMetadata, localKeysList, currentAtSign);
    } else if (atConnectionMetadata.isPolAuthenticated) {
      // TODO: Refactor along with atKey and Scan refactoring.
      localKeysList.removeWhere((key) =>
          key.toString().startsWith('${atConnectionMetadata.fromAtSign}:') ==
              false ||
          key.toString().startsWith('public:_'));
      for (int i = 0; i < localKeysList.length; i++) {
        localKeysList[i] = localKeysList[i]
            .replaceAll('${atConnectionMetadata.fromAtSign}:', '');
      }
      return localKeysList;
    } else {
      localKeysList.removeWhere((key) =>
          key.startsWith('public:_') || key.startsWith('public:') == false);
      for (int i = 0; i < localKeysList.length; i++) {
        localKeysList[i] = localKeysList[i].replaceAll('public:', '');
      }
      return localKeysList;
    }
  }

  /// The commit-log entries visible to this connection, as the JSON-ready
  /// maps `scan:cl` returns, in ascending commitId order:
  /// `{"atKey", "operation" (the CommitOp symbol sync also uses), "commitId",
  /// "opTime" (ISO 8601 UTC)}`.
  ///
  /// The same filters as a keystore scan apply: [scanRegex] against the atKey,
  /// the hidden-key rules ([_isPrivateKeyForAtSign] with [showHiddenKeys]),
  /// and, for an APKAM connection, [_filterKeysBasedOnEnrollmentId]. DELETE
  /// entries are included: an entry for a key that no longer exists is what a
  /// caller pruning commit-log cruft is looking for.
  @visibleForTesting
  Future<List<Map<String, Object?>>> getCommitLogEntries(
      InboundConnectionMetadata atConnectionMetadata,
      String? scanRegex,
      bool showHiddenKeys,
      String currentAtSign) async {
    final commitLog = keyStore.commitLog;
    if (commitLog == null) {
      return [];
    }
    final regex = scanRegex == null ? null : RegExp(scanRegex);
    // At most one entry per atKey, so entries can be keyed by atKey and
    // scan's own enrollment filter reused verbatim.
    final byKey = <String, CommitEntry>{};
    await for (final entry in commitLog.iterate()) {
      final atKey = entry.atKey;
      if (atKey == null || entry.commitId == null) {
        continue;
      }
      if (_isPrivateKeyForAtSign(atKey, showHiddenKeys)) {
        continue;
      }
      if (regex != null && !regex.hasMatch(atKey)) {
        continue;
      }
      byKey[atKey] = entry;
    }
    List<String> visibleKeys = byKey.keys.toList();
    if (!AbstractVerbHandler.isCramConnection(atConnectionMetadata)) {
      if (atConnectionMetadata.enrollmentId == null ||
          atConnectionMetadata.enrollmentId!.isEmpty) {
        visibleKeys = <String>[];
      } else {
        visibleKeys = await _filterKeysBasedOnEnrollmentId(
            atConnectionMetadata, visibleKeys, currentAtSign);
      }
    }
    final entries = visibleKeys.map((key) => byKey[key]!).toList()
      ..sort((a, b) => a.commitId!.compareTo(b.commitId!));
    return entries
        .map((entry) => <String, Object?>{
              'atKey': entry.atKey,
              'operation': entry.operation.name,
              'commitId': entry.commitId,
              'opTime': entry.opTime == null
                  ? null
                  : VerbUtil.formatIso8601Micros(entry.opTime!),
            })
        .toList();
  }

  /// Whether [key] is hidden from a scan: a `private:`, `privatekey:`,
  /// `public:_` or `_` key. [showHiddenKeys] re-admits the hidden public and
  /// self keys (`public:__location@alice`, `_location@alice`).
  bool _isPrivateKeyForAtSign(String key, bool showHiddenKeys) {
    if ((key.startsWith('public:__') || key.startsWith('_')) &&
        showHiddenKeys) {
      return false;
    }
    return key.startsWith('private:') ||
        key.startsWith('privatekey:') ||
        key.startsWith('public:_') ||
        key.startsWith('_');
  }

  /// [localKeysList] narrowed to what the connection's enrollment may read:
  /// the public keys, plus the keys whose namespace it is authorised for.
  /// `__manage` keys and other enrollments' reserved namespaces are excluded
  /// however wide the grant.
  Future<List<String>> _filterKeysBasedOnEnrollmentId(
      InboundConnectionMetadata atConnectionMetadata,
      List<String> localKeysList,
      String currentAtSign) async {
    // Both callers check enrollmentId for null before calling.
    EnrollDataStoreValue enrollment = await AtSecondaryServerImpl.getInstance()
        .enrollmentManager
        .getEnrollmentById(atConnectionMetadata.enrollmentId!);
    var enrollNamespaces = enrollment.namespaces;

    if (enrollNamespaces.isEmpty) {
      logger.finer(
          'For the enrollmentId ${atConnectionMetadata.enrollmentId} no namespaces are enrolled. Returning empty list');
      return [];
    }

    // A namespace grant means nothing once the enrollment has left approved,
    // so such a connection sees only the world-readable public keys. The
    // per-key branch below reaches that verdict on its own through
    // isAuthorized, but the '*' branch never calls it, so without this gate a
    // revoked '*' enrollment would go on enumerating the whole keystore for
    // as long as it held the connection open.
    if (enrollment.approval?.state != EnrollmentStatus.approved.name) {
      logger.warning(
          'Enrollment ${atConnectionMetadata.enrollmentId} is not approved'
          ' (${enrollment.approval?.state}); scan returns public keys only');
      localKeysList.removeWhere((key) => !key.startsWith('public:'));
      return localKeysList;
    }

    // An enrollment holding '*' sees every namespace EXCEPT __manage
    // (enrollment records and key material) and any OTHER enrollment's
    // reserved namespace (<id>.a|r|d.__e); public keys stay visible. This
    // mirrors what isAuthorizedSync decides for the per-key branch below,
    // which this fast path skips.
    if (enrollNamespaces.containsKey(EnrollmentConstants.allNamespaces)) {
      localKeysList.removeWhere((key) =>
          !key.startsWith('public:') &&
          (AbstractVerbHandler.isEnrollManageKey(key) ||
              AbstractVerbHandler.isForeignPerEnrollmentReservedKey(
                  key, atConnectionMetadata.enrollmentId)));
      return localKeysList;
    }

    // Neither no-access nor '*': decide each key individually. Removing a key
    // shortens the list, so "index" advances only when the key is retained.
    int index = 0;
    while (index < localKeysList.length) {
      String key = localKeysList[index];
      if (key.startsWith('public:')) {
        index++;
        continue;
      }
      // No '.' means no namespace, so nothing can authorise it.
      if (!key.contains('.')) {
        localKeysList.remove(key);
        continue;
      }

      bool mayRead = await super.isAuthorized(atConnectionMetadata, atKey: key);
      if (!mayRead) {
        localKeysList.remove(key);
        continue;
      }
      index++;
    }
    return localKeysList;
  }
}
