import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/wire_param_names.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

/// ScanVerbHandler class is used to process scan verb
/// Scan verb will return all the possible keys you can lookup
///Ex: scan\n
class ScanVerbHandler extends AbstractVerbHandler {
  static Scan scan = Scan();
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;

  ScanVerbHandler(
      super.keyStore, this.outboundClientManager, this.cacheManager);

  /// Verifies whether command is accepted or not
  ///
  /// [command]: Input to scan verb
  ///
  /// Return true if command is accepted, else false.
  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.scan));

  /// Returns [Scan] verb.
  @override
  Verb getVerb() {
    return scan;
  }

  /// Process scan Verb. Process the given command and write response to response object.
  ///
  /// [response] - Holds the response from server and sends to the client.
  ///
  /// [verbParams] - Holds the key value pair that matches the regular expression.
  ///
  /// [AtConnection] - The connection which invokes the process verb.
  ///
  /// Throws [UnAuthenticatedException] if forAtSign is not null and connection is not authenticated.
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
        // scan:cl — scan the commit log instead of the keystore, so a
        // client can inspect (and then delete:nc) its entries.
        if (!atConnectionMetadata.isAuthenticated) {
          throw UnAuthenticatedException(
              'scan:cl requires an authenticated connection');
        }
        if ((forAtSign != null && forAtSign.isNotEmpty) &&
            forAtSign != currentAtSign) {
          // The outbound scan proxy cannot forward :cl, so a remote
          // commit-log scan would silently degrade to a plain remote
          // scan — refuse loudly instead.
          throw InvalidRequestException(
              'scan:cl can only scan this atSign\'s own commit log');
        }
        response.data = jsonEncode(await getCommitLogEntries(
            atConnectionMetadata, scanRegex, showHiddenKeys, currentAtSign));
        return;
      }
      // If forAtSign is set, fetch keys that are sharedBy the "forAtSign" to the currentAtSign
      // If currentAtSign is @alice and forAtSign is @bob, fetch all the keys that @bob has
      // created for @alice.
      if ((forAtSign != null && forAtSign.isNotEmpty) &&
          forAtSign != currentAtSign) {
        // When looking up keys of another atSign and connection is not authenticated,
        // Throw UnAuthenticatedException.
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

  /// Fetches the keys of another user atSign
  ///
  /// [forAtSign] : The another user atSign to lookup for keys.
  ///
  /// [scanRegex] : The regular expression to filter the keys
  ///
  /// [atConnection] : The inbound connection
  ///
  /// **Returns**
  ///
  /// String : The another atSign keys returned. Returns null if no keys found.
  Future<String?> _getExternalKeys(String forAtSign, String? scanRegex,
      InboundConnection atConnection) async {
    //scan has to be performed for another atSign
    final OutboundClient outBoundClient = await outboundClientManager
        .getClient(forAtSign, atConnection, handshakeRequired: true);
    var handShake = false;
    // Performs handshake if not done.
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
      if (atConnectionMetadata.enrollmentId == null ||
          atConnectionMetadata.enrollmentId!.isEmpty) {
        return localKeysList;
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
  /// `{"atKey", "operation" (the CommitOp symbol sync also uses),
  /// "commitId", "opTime" (ISO 8601 UTC)}`.
  ///
  /// The same filters as a keystore scan apply: [scanRegex] against the
  /// atKey, the hidden-key rules ([_isPrivateKeyForAtSign] with
  /// [showHiddenKeys]), and — for an APKAM connection — the enrollment
  /// namespace filter ([_filterKeysBasedOnEnrollmentId]). DELETE entries
  /// are included: an entry for a key that no longer exists is exactly
  /// what commit-log cruft management is looking for.
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
    // The commit log holds at most one entry per atKey, so entries can be
    // keyed by atKey and scan's own enrollment filter reused verbatim.
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
    if (atConnectionMetadata.enrollmentId != null &&
        atConnectionMetadata.enrollmentId!.isNotEmpty) {
      visibleKeys = await _filterKeysBasedOnEnrollmentId(
          atConnectionMetadata, visibleKeys, currentAtSign);
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

  /// Checks if a key starts with `public:_`, `private:`, `privatekey:`.
  /// [key] : The key to check.
  /// Returns true if key starts with pattern, else false.
  ///
  /// When showHidden is set true, display hidden keys.
  bool _isPrivateKeyForAtSign(String key, bool showHiddenKeys) {
    // If showHidden is set to true, display hidden public keys/self hidden keys.
    // So returning false
    // public hidden key: public:__location@alice
    // self hidden key: _location@alice
    if ((key.startsWith('public:__') || key.startsWith('_')) &&
        showHiddenKeys) {
      return false;
    }
    return key.startsWith('private:') ||
        key.startsWith('privatekey:') ||
        key.startsWith('public:_') ||
        key.startsWith('_');
  }

  /// Filter keys based on namespace access for the given enrollmentId
  ///
  ///   - If the enrollment namespace contains ".*", returns all the keys.
  ///
  ///   - Returns all the public keys and the keys whose namespace is authorized
  ///     for the given enrollmentId.
  ///
  ///  - If a key's namespace contain "__manage", the key is ignored.
  Future<List<String>> _filterKeysBasedOnEnrollmentId(
      InboundConnectionMetadata atConnectionMetadata,
      List<String> localKeysList,
      String currentAtSign) async {
    // NOTE: The atConnectionMetadata.enrollmentId is verified for null check in the caller of this method - getLocalKeys
    // Therefore, added non-null assertation operator.
    var enrollNamespaces = (await AtSecondaryServerImpl.getInstance()
            .enrollmentManager
            .getEnrollmentById(atConnectionMetadata.enrollmentId!))
        .namespaces;

    // No namespace to filter keys. So, return.
    if (enrollNamespaces.isEmpty) {
      logger.finer(
          'For the enrollmentId ${atConnectionMetadata.enrollmentId} no namespaces are enrolled. Returning empty list');
      return [];
    }
    // If the enrollment holds '*', it sees all namespaces EXCEPT the __manage
    // namespace (enrollment records / key material) and any *other* enrollment's
    // per-enrollment reserved namespace (<id>.a|r|d.__e). Public keys stay
    // visible. This mirrors the isAuthorizedSync gate that the per-key branch
    // below applies for non-'*' enrollments (the '*' fast path skips that loop).
    if (enrollNamespaces.containsKey(EnrollmentConstants.allNamespaces)) {
      localKeysList.removeWhere((key) =>
          !key.startsWith('public:') &&
          (AbstractVerbHandler.isEnrollManageKey(key) ||
              AbstractVerbHandler.isForeignPerEnrollmentReservedKey(
                  key, atConnectionMetadata.enrollmentId)));
      return localKeysList;
    }

    // We've dealt with no access and with '*' access; now we have to check
    // access on each key individually.
    int index = 0;
    // Iterates through the list of local keys.
    // Removes the key from the list if any of the below condition is met:
    // 1. If a key does not have namespace
    // 2. If key is an enrollment key - key whose namespace is "__manage"
    // 3. If a keys namespace is not authorised in the enrollment.
    // If a key is removed, the length of the list is reduced. To prevent skipping
    // of the keys in the list, do not increment "index". Increment "index" only
    // if key is not removed.
    while (index < localKeysList.length) {
      String key = localKeysList[index];
      // Retain public keys
      if (key.startsWith('public:')) {
        index++;
        continue;
      }
      // If key does not have ".", it indicates key does not have namespace
      // Do not show it in scan result.
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
