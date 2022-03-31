import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_utils.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_secondary/src/verb/handler/sync_handler_helpers.dart';
import 'package:mutex/mutex.dart';

class SyncStreamVerbHandler extends AbstractVerbHandler {
  static SyncStream syncStreamVerb = SyncStream();

  SyncStreamVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  @override
  bool accept(String command) {
    return command.startsWith('ssync:from:') || command.startsWith('ssync:ack1');
  }

  @override
  Verb getVerb() {
    return syncStreamVerb;
  }

  @override
  Future<void> processVerb(Response response, HashMap<String, String?> verbParams, InboundConnection atConnection) async {
    if (verbParams.containsKey(AT_FROM_COMMIT_SEQUENCE)) {
      await _processSSyncFrom(response, verbParams, atConnection);
    } else {
      //  can only be an 'ssync:ack1' request. see accept() above
      _processSSyncAck1(response, verbParams, atConnection);
    }
  }

  _processSSyncAck1(Response response, HashMap<String, String?> verbParams, InboundConnection inboundConnection) {
    var inboundConnectionMetadata = inboundConnection.getMetaData() as InboundConnectionMetadata;
    if (! inboundConnectionMetadata.isSyncStream) {
      // Should only receive ssync:ack1 requests when we've already handled an ssync:from: request on this connection
      throw AtInvalidStateException("ssync:from: has not yet been received on this connection");
    }
    _CommitLogStreamer _commitLogStreamer = inboundConnectionMetadata.commitLogStreamer as _CommitLogStreamer;
    _commitLogStreamer.decrementNumAwaitingAck();
  }

  Future<void> _processSSyncFrom(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection inboundConnection) async {
    var inboundConnectionMetadata = inboundConnection.getMetaData() as InboundConnectionMetadata;
    if (inboundConnectionMetadata.isSyncStream) {
      // We've already set up a sync stream on this connection, this is an error
      throw AtInvalidStateException("ssync:from: has already been received on this connection");
    }
    inboundConnectionMetadata.isSyncStream = true;

    String? regex = verbParams['regex'];
    if (regex == null || regex.isEmpty) {
      regex = '.*';
    }

    // set up the commit log listener.
    // Note that we will not stream to client from the listener until we've marked it as 'initialized'
    _CommitLogStreamer commitLogStreamer = _CommitLogStreamer(keyStore!, inboundConnection, regex);
    var atCommitLog = await (AtCommitLogManagerImpl.getInstance()
        .getCommitLog(AtSecondaryServerImpl.getInstance().currentAtSign));
    atCommitLog!.addEventListener(commitLogStreamer);
    inboundConnectionMetadata.commitLogStreamer = commitLogStreamer;

    // Get Commit Log Instance.
    // Get entries to sync
    var itr = atCommitLog.getEntries(
        int.parse(verbParams[AT_FROM_COMMIT_SEQUENCE]!) + 1,
        regex: regex);
    // Iterates on all the elements in iterator
    // Loop breaks when the [syncBuffer] reaches the limit.
    // and when syncResponse length equals the [AtSecondaryConfig.syncPageLimit]
    while (itr.moveNext()) {
      var keyStoreEntry = KeyStoreEntry();
      keyStoreEntry.atKey = itr.current.key;
      keyStoreEntry.commitId = itr.current.value.commitId;
      keyStoreEntry.operation = itr.current.value.operation;
      await commitLogStreamer.queueForStreaming(keyStoreEntry);
    }

    await commitLogStreamer.startLiveStreaming();
  }

  void logResponse(String response) {
    try {
      var parsedResponse = '';
      final responseJson = jsonDecode(response);
      for (var syncRecord in responseJson) {
        final newRecord = {};
        newRecord['atKey'] = syncRecord['atKey'];
        newRecord['operation'] = syncRecord['operation'];
        newRecord['commitId'] = syncRecord['commitId'];
        newRecord['metadata'] = syncRecord['metadata'];
        parsedResponse += newRecord.toString();
      }
      logger.finer('progressive sync response: $parsedResponse');
    } on Exception catch (e, trace) {
      logger.severe(
          'exception logging progressive sync response: ${e.toString()}');
      logger.severe(trace);
    }
  }
}

abstract class CommitLogStreamer implements AtChangeEventListener {
  Future<void> close();
  bool isClosed();
}

class _CommitLogStreamer implements CommitLogStreamer {
  final logger = AtSignLogger('_StreamSyncCommitLogListener');

  final Mutex _initializedMutex = Mutex();

  int _lastCommitIdQueuedForStreaming = -1;

  final SecondaryKeyStore _keyStore;
  final InboundConnection _inboundConnection;
  final String _regex;
  late final InboundConnectionMetadata _inboundConnectionMetadata;
  final Queue<KeyStoreEntry> _pendingQueue = Queue<KeyStoreEntry>();
  final Queue<KeyStoreEntry> _streamingQueue = Queue<KeyStoreEntry>();

  bool _initialized = false;
  bool _closed = false;

  _CommitLogStreamer(this._keyStore, this._inboundConnection, this._regex) {
    logger.level = 'finer';
    _inboundConnectionMetadata = _inboundConnection.getMetaData() as InboundConnectionMetadata;
  }

  @override
  bool isClosed() => _closed;

  @override
  Future<void> close() async {
    if (! _closed) {
      var atCommitLog = await(AtCommitLogManagerImpl.getInstance()
          .getCommitLog(AtSecondaryServerImpl
          .getInstance()
          .currentAtSign));
      atCommitLog!.removeEventListener(this);

      _inboundConnectionMetadata.commitLogStreamer = null;
      _inboundConnectionMetadata.isSyncStream = false;

      _pendingQueue.clear();
      _streamingQueue.clear();

      _closed = true;
    }
  }

  /// * Receives a [AtPersistenceChangeEvent] from the commit log change stream
  /// * Constructs a [KeyStoreEntry] from the event (key, commitId, operation)
  /// * For all ops other than DELETE:
  ///   * Checks if key still exists - if not, return
  ///   * Checks if the data is null for this key - if not, return
  ///   * Adds the data and metadata to the KeyStoreEntry
  /// * Lastly, if the server has been initialized, sends to the streaming queue, otherwise adds to the pending queue
  @override
  Future<void> listen(AtPersistenceChangeEvent atChangeEvent) async {
    KeyStoreEntry keyStoreEntry = KeyStoreEntry();
    keyStoreEntry.atKey = atChangeEvent.key;
    keyStoreEntry.commitId = atChangeEvent.value;
    keyStoreEntry.operation = atChangeEvent.commitOp;

    if (! AtKeyUtils.atKeyMatchesRegexForSync(keyStoreEntry.atKey, _regex)) {
      return;
    }

    if (ignoreCommitIds.contains(keyStoreEntry.commitId)) {
      logger.finer('Not sending Commit Log Entry ${keyStoreEntry.commitId} to this client (which triggered it)');
      ignoreCommitIds.remove(keyStoreEntry.commitId);
      return;
    }

    try {
      await _initializedMutex.acquire();
      if (_initialized) {
        await queueForStreaming(keyStoreEntry);
      } else {
        _pendingQueue.add(keyStoreEntry);
      }
    } finally {
      _initializedMutex.release();
    }
  }

  /// Once all of the entries have been gathered
  /// * lock the streamer
  /// * note the last queued-for-client commit id
  /// * only send commit entries from the 'pending' queue where commit id > the last-queued-for-client id
  /// * mark as initialized (new events will go direct to the streaming queue rather than the pending queue)
  Future<void> startLiveStreaming() async {
    try {
      await _initializedMutex.acquire();
      for (KeyStoreEntry pendingEntry in _pendingQueue) {
        if (pendingEntry.commitId > _lastCommitIdQueuedForStreaming) {
          _queueForStreaming(pendingEntry); // Calling the private method because we've already grabbed the mutex
        }
      }
      _pendingQueue.clear();
      _initialized = true;
    } finally {
      _initializedMutex.release();
    }
  }

  /// Grabs mutex, immediately queues the [KeyStoreEntry] for streaming
  Future<void> queueForStreaming(KeyStoreEntry keyStoreEntry) async {
    try {
      await _initializedMutex.acquire();
      _queueForStreaming(keyStoreEntry);
    } finally {
      _initializedMutex.release();
    }
  }

  ///
  /// Internal only - does not grab the mutex
  _queueForStreaming(KeyStoreEntry keyStoreEntry) {
    _streamingQueue.add(keyStoreEntry);
    _lastCommitIdQueuedForStreaming = keyStoreEntry.commitId;

    _processStreamingQueue();
  }

  bool _isProcessingQueue = false;
  bool get isProcessingQueue => _isProcessingQueue;

  Set<int> ignoreCommitIds = <int>{};

  int _numAwaitingAck = 0;
  int get numAwaitingAck => _numAwaitingAck;

  void decrementNumAwaitingAck() {
    _numAwaitingAck--;
  }
  void incrementNumAwaitingAck() {
    _numAwaitingAck++;
  }

  void _processStreamingQueue() {
    if (_closed) {
      return;
    }
    if (_inboundConnection.isInValid()) {
      Future.delayed(Duration(milliseconds: 0)).then((value) async {
        await close();
      });
      return;
    }
    int syncStreamInFlightLimit = AtSecondaryConfig.syncStreamInFlightLimit;

    if (_isProcessingQueue || _streamingQueue.isEmpty) {
      return;
    }

    _isProcessingQueue = true;
    logger.finer("Starting queue processor - set isProcessingQueue to true");

    Future.delayed(Duration(milliseconds: 0)).then((value) async {
      while (_streamingQueue.isNotEmpty && _numAwaitingAck < syncStreamInFlightLimit) {
        KeyStoreEntry keyStoreEntry = _streamingQueue.removeFirst();
        if (keyStoreEntry.operation != CommitOp.DELETE) {
          // If commitOperation is update (or) update_all (or) update_meta and key does not
          // exist in keystore, skip the key to sync and continue.
          if (!_keyStore.isKeyExists(keyStoreEntry.atKey)) {
            logger.finer('${keyStoreEntry.atKey} does not exist in the keystore. Will not sync to client.');
            continue;
          }

          // ignore: prefer_typing_uninitialized_variables
          var atData;
          try {
            atData = await _keyStore.get(keyStoreEntry.atKey);
          } catch (e) {
            logger.warning("Queue processor caught $e from _sendCommitEntryToClient($keyStoreEntry)");
          }
          if (atData == null) {
            logger.finer('atData is null for ${keyStoreEntry.atKey}. Will not sync to client.');
            continue;
          }
          keyStoreEntry.value = atData.data;
          keyStoreEntry.atMetaData = populateMetadata(atData);
        }

        try {
          await _sendCommitEntryToClient(keyStoreEntry);
        } catch (e) {
          logger.warning("Queue processor caught $e from _sendCommitEntryToClient($keyStoreEntry)");
        }
      }
      _isProcessingQueue = false;
      logger.finer("Queue processor finished - set isProcessingQueue to false");
    }).catchError((error) {
      _isProcessingQueue = false;
      logger.severe("Queue processor caught error - set isProcessingQueue to false");
    });
  }

  Future<dynamic> _sendCommitEntryToClient (KeyStoreEntry keyStoreEntry) async {
    if (! _inboundConnection.isInValid()) {
      _inboundConnection.write(jsonEncode(keyStoreEntry));
    }
  }

  @override
  ignoreCommitId(int commitId) {
    ignoreCommitIds.add(commitId);
  }
}
