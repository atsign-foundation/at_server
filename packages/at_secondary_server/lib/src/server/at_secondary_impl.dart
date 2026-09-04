// ignore_for_file: prefer_typing_uninitialized_variables

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:at_commons/at_commons.dart' hide StringBuffer;
import 'package:at_lookup/at_lookup.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/caching/cache_refresh_job.dart';
import 'package:at_secondary/src/compaction/at_compaction_stats_service_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart'
    show OutboundConnectionFactory, DefaultOutboundConnectionFactory;
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/stream_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_certificate_validation.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/persistence_backend.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:crypton/crypton.dart';
import 'package:meta/meta.dart';

import 'http_request_handler.dart';

/// Singleton implementation of [AtSecondaryServer].
class AtSecondaryServerImpl implements AtSecondaryServer {
  static final bool? useTLS = AtSecondaryConfig.useTLS;
  static final AtSecondaryServerImpl _singleton =
      AtSecondaryServerImpl._internal();

  static final int? expiringRunFreqMins = AtSecondaryConfig.expiringRunFreqMins;

  late SecondaryAddressFinder secondaryAddressFinder;
  late OutboundClientManager outboundClientManager;
  late OutboundConnectionFactory outboundConnectionFactory;

  late bool _isPaused;

  var logger = AtSignLogger('AtSecondaryServer');

  /// Builds the per-atSign persistence stores during [start] and tears them
  /// down during [stop]. Replaceable before [start] is called.
  AtPersistenceFactory persistenceFactory = HiveAtPersistenceFactory();

  /// The bundle this server is currently running against.
  AtPersistenceBundle? _persistenceBundle;

  factory AtSecondaryServerImpl.getInstance() {
    return _singleton;
  }

  AtSecondaryServerImpl._internal() {
    logger.shout('executableArguments: ${Platform.executableArguments}');
    logger.shout('DART_VM_OPTIONS: ${Platform.environment['DART_VM_OPTIONS']}');

    // NOTE these are initialized here as well as in [start], because unit
    // tests depend on them without starting the server.
    final socketConfig = SecureSocketConfig()
      ..decryptPackets = false
      ..pathToCerts = AtSecondaryConfig.trustedCertificateLocation
      ..tlsKeysSavePath = null;

    secondaryAddressFinder = CacheableSecondaryAddressFinder(
      AtSecondaryConfig.rootServerUrl,
      AtSecondaryConfig.rootServerPort,
      socketConfig: socketConfig,
    );
    outboundConnectionFactory = DefaultOutboundConnectionFactory(
      clientCertificateRequired: false, // so unit tests can work
    );
    outboundClientManager = OutboundClientManager(
      secondaryAddressFinder,
      outboundConnectionFactory,
    );
  }

  dynamic _serverSocket;
  bool _isRunning = false;
  late Atsign currentAtSign;
  late AtCommitLog commitLog;
  late AtAccessLog accessLog;
  var signingKey;
  AtSecondaryContext? serverContext;
  VerbExecutor? executor;
  VerbHandlerManager? verbHandlerManager;
  late AtCacheRefreshJob atRefreshJob;
  late AtCacheManager cacheManager;
  final StatsNotificationService statsNotificationService =
      StatsNotificationService();

  /// Timers driving the per-resource compaction cron, each on its own
  /// configured frequency.
  final List<Timer> _compactionTimers = [];

  /// One-shot timer driving [runHousekeepingSweep], re-armed after every
  /// sweep so the server sleeps until the next key expires.
  Timer? _keyExpiryTimer;

  /// Floor for the expiry-sweep sleep.
  static const Duration _minExpirySleep = Duration(seconds: 10);
  @visibleForTesting
  AtCertificateValidationJob? certificateReloadJob;
  late AtKeyValueStore<String, AtData, AtMetaData?> keyValueStore;
  late AtNotificationKeystore notificationKeystore;
  late NotificationManager notificationManager;
  late EnrollmentManager enrollmentManager;
  late InboundConnectionManager inboundConnectionManager;

  @override
  void setExecutor(VerbExecutor executor) {
    this.executor = executor;
  }

  @override
  void setVerbHandlerManager(VerbHandlerManager verbManager) {
    verbHandlerManager = verbManager;
  }

  @override
  void setServerContext(AtServerContext context) {
    serverContext = context as AtSecondaryContext?;
  }

  @override
  bool isRunning() {
    return _isRunning == true;
  }

  /// Starts the secondary server, secured or unsecured according to
  /// configuration. Throws [AtServerException] if the server cannot be
  /// started.
  ///
  /// Runs more than once per process, as [AtCertificateValidationJob] calls
  /// [stop] and then [start] again on this singleton to pick up replaced TLS
  /// certificates.
  @override
  Future<void> start() async {
    pause();
    if (_isRunning) {
      return;
    }

    if (serverContext == null) {
      throw AtServerException('Server context is not initialized');
    }

    if (executor == null) {
      throw AtServerException('Verb executor is not initialized');
    }


    if (useTLS! && serverContext!.securityContext == null) {
      throw AtServerException('Security context is not set');
    }

    if (serverContext!.currentAtSign == null) {
      throw AtServerException('User atSign is not set');
    }

    currentAtSign = serverContext!.currentAtSign!.toAtsign();
    logger.shout('start(): currentAtSign : $currentAtSign');

    await _initializePersistentInstances();

    if (!serverContext!.isKeyStoreInitialized) {
      throw AtServerException('Secondary keystore is not initialized');
    }

    enrollmentManager = EnrollmentManager(keyValueStore, currentAtSign);
    List<String> deletedKeys =
        await enrollmentManager.removeLegacyApkamPublicKeys();
    if (deletedKeys.isNotEmpty) {
      logger.info('Removed legacy APKAM public keys: $deletedKeys');
    }
    deletedKeys = await enrollmentManager.removeOrphanedApkamEncryptionKeys();
    if (deletedKeys.isNotEmpty) {
      logger.info('Removed orphaned APKAM encryption keys: $deletedKeys');
    }

    await prepareStoreForFirstConnection();

    await _scheduleNextExpirySweep();

    final statsService = AtCompactionStatsService(keyValueStore);
    if (AtSecondaryConfig.enableCommitLogCompactor) {
      _scheduleCompaction(
        commitLog,
        Duration(minutes: AtSecondaryConfig.commitLogCompactionFrequencyMins),
        'commitLog',
        statsService,
      );
    }
    if (AtSecondaryConfig.enableAccessLogCompactor) {
      _scheduleCompaction(
        accessLog,
        Duration(minutes: AtSecondaryConfig.accessLogCompactionFrequencyMins),
        'accessLog',
        statsService,
      );
    }
    if (AtSecondaryConfig.enableNotificationCompactor) {
      _scheduleCompaction(
        notificationKeystore,
        Duration(
            minutes:
                AtSecondaryConfig.notificationKeyStoreCompactionFrequencyMins),
        'notificationKeystore',
        statsService,
      );
    }

    final socketConfig = SecureSocketConfig()
      ..decryptPackets = false
      ..pathToCerts = AtSecondaryConfig.trustedCertificateLocation
      ..tlsKeysSavePath = null;

    secondaryAddressFinder = CacheableSecondaryAddressFinder(
      AtSecondaryConfig.rootServerUrl,
      AtSecondaryConfig.rootServerPort,
      socketConfig: socketConfig,
    );
    outboundConnectionFactory = DefaultOutboundConnectionFactory(
      clientCertificateRequired: AtSecondaryConfig.clientCertificateRequired,
    );
    outboundClientManager = OutboundClientManager(
      secondaryAddressFinder,
      outboundConnectionFactory,
      poolSize: serverContext!.outboundConnectionLimit,
    );

    notificationManager = NotificationManager(
        currentAtSign,
        notificationKeystore,
        NotifyConnectionsPool(
          secondaryAddressFinder,
          outboundConnectionFactory,
          poolSize: serverContext!.outboundConnectionLimit,
        ));

    cacheManager = AtCacheManager(serverContext!.currentAtSign!, keyValueStore,
        outboundClientManager, notificationManager);

    var random = Random();
    var runRefreshJobHour = random.nextInt(23);
    atRefreshJob =
        AtCacheRefreshJob(serverContext!.currentAtSign!, cacheManager);
    atRefreshJob.scheduleRefreshJob(runRefreshJobHour);

    AtSecondaryConfig.subscribe(ModifiableConfigs.doCacheRefreshNow)
        ?.listen((newValue) async {
      if (newValue.toString() == 'true') {
        unawaited(atRefreshJob.refreshNow());
      }
    });

    if (verbHandlerManager == null) {
      verbHandlerManager = DefaultVerbHandlerManager(
        keyValueStore,
        outboundClientManager,
        cacheManager,
        statsNotificationService,
        notificationManager,
        enrollmentManager,
        currentAtSign,
        commitLog: commitLog,
        accessLog: accessLog,
      );
    } else {
      // NOTE a restart needs a new manager, holding the current stores.
      if (verbHandlerManager is DefaultVerbHandlerManager) {
        verbHandlerManager = DefaultVerbHandlerManager(
          keyValueStore,
          outboundClientManager,
          cacheManager,
          statsNotificationService,
          notificationManager,
          enrollmentManager,
          currentAtSign,
          commitLog: commitLog,
          accessLog: accessLog,
        );
      }
    }

    // NOTE one job per process: it is what drives a soft restart.
    if (certificateReloadJob == null) {
      certificateReloadJob = AtCertificateValidationJob(
          this,
          AtSecondaryConfig.certificateChainLocation
              .replaceAll('fullchain.pem', 'restart'),
          AtSecondaryConfig.isForceRestart);
      await certificateReloadJob!.start();

      AtSecondaryConfig.subscribe(ModifiableConfigs.checkCertificateReload)
          ?.listen((newValue) async {
        if (newValue.toString() == 'true') {
          unawaited(certificateReloadJob!
              .checkAndRestartIfRequired(forceRestartThisTime: true));
        }
      });

      AtSecondaryConfig.subscribe(ModifiableConfigs.shouldReloadCertificates)
          ?.listen((newValue) async {
        if (newValue.toString() == 'true') {
          await certificateReloadJob!.createRestartFile();
        } else if (newValue.toString() == 'false') {
          await certificateReloadJob!.deleteRestartFile();
        }
      });
    }
    await certificateReloadJob!.deleteRestartFile();

    inboundConnectionManager = InboundConnectionManager(
        serverAtSign: currentAtSign,
        poolSize: serverContext!.inboundConnectionLimit);

    await statsNotificationService.schedule(currentAtSign, commitLog);

    await initDynamicConfigListeners();

    await removeMalformedKeys();

    int removed, failed;
    (removed, failed) = await notificationManager.removeExpired();
    logger.info(
        'NotificationManager.removeExpired: Removed $removed ; Failed $failed');

    if (!useTLS!) {
      throw AtServerException('Only TLS is supported; useTLS must be true');
    }
    try {
      _isRunning = true;
      if (useTLS!) {
        await _startSecuredServer();
      } else {
        await _startUnSecuredServer();
      }
    } catch (e, stacktrace) {
      _isRunning = false;
      logger.severe('AtSecondaryServer().start : ${e.toString()}');
      logger.severe(stacktrace);
      throw AtServerException(e.toString());
    }

    if (serverContext!.trainingMode) {
      try {
        logger.warning('Training mode set - stopping server');
        await Future.delayed(Duration(milliseconds: 100));
        await stop();
      } catch (e) {
        logger.severe('Caught exception $e in server stop()');
      }
      logger.warning('Training mode set - exiting');
      exit(0);
    }

    await notificationManager.reEnqueueUndelivered();

    resume();
  }

  /// Restarts compaction with a new frequency for the resource identified by
  /// [label]. Works only when testing mode is set.
  Future<void> _restartCompaction(
    Compactable resource,
    Duration newFrequency,
    String label,
    AtCompactionStatsService statsService,
  ) async {
    logger.finest(
        'Received new frequency for $label compaction: ${newFrequency.inMinutes}m');
    // NOTE timers are not indexed by label, so all are cancelled and the one
    // being changed is re-scheduled.
    for (final t in _compactionTimers) {
      t.cancel();
    }
    _compactionTimers.clear();
    _scheduleCompaction(resource, newFrequency, label, statsService);
  }

  /// Everything the keystore needs done before a client can connect, in the
  /// order it has to happen.
  ///
  /// Both remove hooks are registered before the expired-keys sweep.
  @visibleForTesting
  Future<void> prepareStoreForFirstConnection() async {
    keyValueStore.preRemoveHooks.add(enrollmentManager.preRemoveHook);
    keyValueStore.postRemoveHooks.add(enrollmentManager.postRemoveHook);

    // NOTE before the sweep, so an expired root about to be reaped is not the
    // survivor that licenses deleting a copy of its key.
    final StartupFlatKeyOutcome migrated =
        await enrollmentManager.migrateFlatKeyAtStartup();
    logger.info('Flat legacy credential at startup: ${migrated.name}');

    await runHousekeepingSweep();
  }

  /// One pass of the periodic store housekeeping: reap expired keys.
  @visibleForTesting
  Future<void> runHousekeepingSweep() async {
    await keyValueStore.deleteExpiredKeys();
  }

  /// Computes the next expiry-sweep wake-up from
  /// [AtKeyValueStore.nextExpiresAt] and arms [_keyExpiryTimer].
  ///
  /// Sleep is clamped to `[_minExpirySleep, expiringRunFreqMins]`, plus a
  /// 0-30s jitter.
  Future<void> _scheduleNextExpirySweep() async {
    if (_persistenceBundle == null) {
      return;
    }
    final maxSleep = Duration(minutes: expiringRunFreqMins!);
    Duration sleep;
    try {
      final DateTime? next = await keyValueStore.nextExpiresAt();
      if (next == null) {
        sleep = maxSleep;
      } else {
        final untilNext = next.difference(DateTime.timestamp());
        sleep = untilNext < _minExpirySleep
            ? _minExpirySleep
            : (untilNext > maxSleep ? maxSleep : untilNext);
      }
    } on Exception catch (e) {
      logger.warning('Failed to compute next expiry wake-up: $e');
      sleep = maxSleep;
    }
    sleep += Duration(seconds: Random().nextInt(30));
    logger.finest('Next key expiry sweep in $sleep');
    _keyExpiryTimer = Timer(sleep, () async {
      if (_persistenceBundle == null) {
        return;
      }
      await onExpirySweepTimerFired();
      await _scheduleNextExpirySweep();
    });
  }

  /// What the expiry timer does when it fires: one housekeeping sweep, with a
  /// failure logged rather than propagated into the timer.
  @visibleForTesting
  Future<void> onExpirySweepTimerFired() async {
    try {
      await runHousekeepingSweep();
    } on Exception catch (e) {
      logger.warning('Key expiry sweep failed: $e');
    }
  }

  /// Schedules a periodic compaction tick for [resource]. The tick drains
  /// `compact(false)` with an overlap guard and records the pass via
  /// [statsService].
  void _scheduleCompaction(
    Compactable resource,
    Duration period,
    String label,
    AtCompactionStatsService statsService,
  ) {
    bool running = false;
    _compactionTimers.add(Timer.periodic(period, (_) async {
      if (running) return;
      running = true;
      try {
        final start = DateTime.timestamp();
        var count = 0;
        await for (final _ in resource.compact(false)) {
          count++;
        }
        final duration = DateTime.timestamp().difference(start);
        logger.info(
            'compacted $label: dropped $count entries in ${duration.inMilliseconds}ms');
        await statsService.record(
          label: label,
          start: start,
          compactedCount: count,
          duration: duration,
        );
      } catch (e, st) {
        logger.warning('compaction failed for $label: $e\n$st');
      } finally {
        running = false;
      }
    }));
  }

  Future<void> initDynamicConfigListeners() async {
    logger.finest('Subscribing to dynamic changes made to inbound_max_limit');
    AtSecondaryConfig.subscribe(ModifiableConfigs.inboundMaxLimit)
        ?.listen((newSize) {
      inboundConnectionManager.pool.resize(newSize);
      logger.finest(
          'inbound_max_limit change received. Modifying inbound_max_limit of server to $newSize');
    });

    final statsService = AtCompactionStatsService(keyValueStore);

    logger.finest(
        'Subscribing to dynamic changes made to notificationKeystoreCompactionFreq');
    AtSecondaryConfig.subscribe(
            ModifiableConfigs.notificationKeyStoreCompactionFrequencyMins)
        ?.listen((newFrequency) async {
      await _restartCompaction(
          notificationKeystore,
          Duration(minutes: newFrequency),
          'notificationKeystore',
          statsService);
    });

    logger.finest(
        'Subscribing to dynamic changes made to accessLogCompactionFreq');
    AtSecondaryConfig.subscribe(
            ModifiableConfigs.accessLogCompactionFrequencyMins)
        ?.listen((newFrequency) async {
      await _restartCompaction(accessLog, Duration(minutes: newFrequency),
          'accessLog', statsService);
    });

    logger.finest(
        'Subscribing to dynamic changes made to commitLogCompactionFreq');
    AtSecondaryConfig.subscribe(
            ModifiableConfigs.commitLogCompactionFrequencyMins)
        ?.listen((newFrequency) async {
      await _restartCompaction(commitLog, Duration(minutes: newFrequency),
          'commitLog', statsService);
    });

    logger.finest('Subscribing to dynamic changes made to autoNotify');
    late bool autoNotifyState;
    AtSecondaryConfig.subscribe(ModifiableConfigs.autoNotify)
        ?.listen((newValue) {
      if (newValue.toString() == 'true') {
        autoNotifyState = true;
      } else if (newValue.toString() == 'false') {
        autoNotifyState = false;
      }
      logger.finest(
          'Received new value for config \'autoNotify\': $autoNotifyState');
      AbstractUpdateVerbHandler.setAutoNotify(autoNotifyState);
      DeleteVerbHandler.setAutoNotify(autoNotifyState);
    });

    AtSecondaryConfig.subscribe(ModifiableConfigs.maxRequestsPerTimeFrame)
        ?.listen((maxEnrollRequestsAllowed) {
      AtSecondaryConfig.maxEnrollRequestsAllowed = maxEnrollRequestsAllowed;
    });

    AtSecondaryConfig.subscribe(ModifiableConfigs.timeFrameInMillis)
        ?.listen((timeWindowInMills) {
      AtSecondaryConfig.timeFrameInMillis = timeWindowInMills;
    });
  }

  webSocketListener(WebSocket ws) async {
    InboundConnection? connection;
    try {
      connection = inboundConnectionManager.createWebSocketConnection(ws,
          sessionId: SecondaryUtil.makeSessionId());
      connection.acceptRequests(_executeVerbCallBack, _streamCallBack);
      await connection.write('@');
    } on InboundConnectionLimitException catch (e) {
      await GlobalExceptionHandler.getInstance()
          .handle(e, atConnection: connection, clientSocket: ws);
    }
  }

  /// Listens on the secondary server socket and creates an inbound connection
  /// for each client socket. Throws [SocketException] for socket errors.
  void _listen(final serverSocket) {
    // NOTE sockets whose ALPN selectedProtocol is neither null nor
    // 'atProtocol/1.0' are handed to the PseudoServerSocket.
    final pseudoServerSocket = PseudoServerSocket(serverSocket);
    HttpServer httpServer = HttpServer.listenOn(pseudoServerSocket);
    final httpReqHandler =
        AtServerHttpRequestHandler(currentAtSign, keyValueStore);
    httpServer.listen((HttpRequest req) {
      if (req.uri.path == '/ws') {
        logger.info('Upgraded to WebSocket connection');
        WebSocketTransformer.upgrade(req)
            .then((WebSocket ws) => webSocketListener(ws));
      } else {
        httpReqHandler.handle(req);
      }
    });

    logger.finer('serverSocket _listen : ${serverSocket.runtimeType}');
    serverSocket.listen(((clientSocket) async {
      if (logger.isLoggable('finer')) {
        logger.finer(
            'New client socket: selectedProtocol ${clientSocket.selectedProtocol}');
      }
      if (clientSocket.selectedProtocol == 'atProtocol/1.0' ||
          clientSocket.selectedProtocol == null) {
        InboundConnection? connection;
        try {
          if (logger.isLoggable('finer')) {
            logger.finer(
                'In _listen - clientSocket.peerCertificate : ${clientSocket.peerCertificate}');
          }
          connection = inboundConnectionManager.createSocketConnection(
              clientSocket,
              sessionId: SecondaryUtil.makeSessionId());
          connection.acceptRequests(_executeVerbCallBack, _streamCallBack);
          await connection.write('@');
        } on InboundConnectionLimitException catch (e) {
          await GlobalExceptionHandler.getInstance()
              .handle(e, atConnection: connection, clientSocket: clientSocket);
        }
      } else {
        logger.info('Transferring socket to HttpServer for handling');
        pseudoServerSocket.add(clientSocket);
      }
    }), onError: (error) {
      logger.warning("ServerSocket.listen called onError with '$error'");
    });
  }

  /// Starts the secondary server in secure mode and listens on its socket.
  Future<void> _startSecuredServer() async {
    var secCon = SecurityContext.defaultContext;
    var retryCount = 0;
    var certsAvailable = false;
    // if certs are unavailable then retry max 10 minutes
    while (true) {
      try {
        if (certsAvailable || retryCount > 60) {
          break;
        }
        secCon
            .useCertificateChain(serverContext!.securityContext!.publicKeyPath);
        secCon.usePrivateKey(serverContext!.securityContext!.privateKeyPath);
        secCon.setTrustedCertificates(
            serverContext!.securityContext!.trustedCertificatePath);
        certsAvailable = true;
        secCon.setAlpnProtocols(['atProtocol/1.0', 'http/1.1'], true);
      } on FileSystemException catch (e) {
        retryCount++;
        logger.info('${e.message}:${e.path}');
        logger.info('certs unavailable. Retry count $retryCount');
        await Future.delayed(Duration(seconds: 10));
      }
    }
    if (certsAvailable) {
      _serverSocket = await SecureServerSocket.bind(
          InternetAddress.anyIPv4, serverContext!.port, secCon,
          requestClientCertificate: true);
      logger.shout(
          'Secondary server started on version : ${AtSecondaryConfig.secondaryServerVersion} on root server : ${AtSecondaryConfig.rootServerUrl}');
      logger.shout('Secure Socket open for $currentAtSign !');
      _listen(_serverSocket);
    } else {
      logger.severe('certs not available');
    }
  }

  /// Starts the secondary server in unsecured mode and listens on its socket.
  Future<void> _startUnSecuredServer() async {
    _serverSocket =
        await ServerSocket.bind(InternetAddress.anyIPv4, serverContext!.port);
    logger.shout('Unsecure Socket open');
    _listen(_serverSocket);
  }

  /// Executes [command] on [connection].
  /// Throws [InternalServerError] if the server fails to process it.
  void _executeVerbCallBack(
      String command, InboundConnection connection) async {
    if (logger.isLoggable('finer')) {
      logger.finer(logger.getAtConnectionLogMessage(
          connection.metaData, 'inside _executeVerbCallBack: $command'));
    }
    try {
      if (_isPaused) {
        await GlobalExceptionHandler.getInstance().handle(
            ServerIsPausedException(
                'Server is temporarily paused and should be available again shortly'),
            atConnection: connection);
        return;
      }

      await executor!.execute(command, connection, verbHandlerManager!);
    } on Exception catch (e, st) {
      await GlobalExceptionHandler.getInstance()
          .handle(e, stackTrace: st, atConnection: connection);
    } on Error catch (e, st) {
      await GlobalExceptionHandler.getInstance().handle(
          InternalServerError(e.toString()),
          stackTrace: st,
          atConnection: connection);
    } catch (e, st) {
      await GlobalExceptionHandler.getInstance().handle(
          InternalServerError(e.toString()),
          stackTrace: st,
          atConnection: connection);
    }
  }

  void _streamCallBack(List<int> data, InboundConnection sender) {
    var streamId = sender.metaData.streamId;
    logger.finer(logger.getAtConnectionLogMessage(
        sender.metaData, 'stream id:$streamId'));
    if (_isPaused) {
      GlobalExceptionHandler.getInstance().handle(
          ServerIsPausedException(
              'Server is temporarily paused and should be available again shortly'),
          atConnection: sender);
      return;
    }
    if (streamId != null) {
      StreamManager.receiverSocketMap[streamId]!.underlying.add(data);
    }
  }

  /// Removes all the active connections and stops the secondary server.
  /// Throws [AtServerException] if the server cannot be stopped.
  ///
  /// Half of a restart, so everything [start] acquires must be released here.
  /// [certificateReloadJob] is the exception, and survives on purpose.
  @override
  Future<void> stop() async {
    pause();
    try {
      logger.shout("Executing server stop()");

      logger.shout("Closing ServerSocket");
      _serverSocket.close();

      logger.shout("Stopping StatsNotificationService");
      await statsNotificationService.cancel();

      logger.shout("Terminating all inbound connections");
      inboundConnectionManager.close();

      logger.shout("Closing Notification Manager");
      await notificationManager.close();

      keyValueStore.preRemoveHooks.clear();
      keyValueStore.postRemoveHooks.clear();

      logger.shout("Stopping key expiry timer");
      _keyExpiryTimer?.cancel();
      _keyExpiryTimer = null;

      logger.shout('Closing persistence (commit log, access log, '
          'notification keystore, secondary keystore)');
      await persistenceFactory.close();
      _persistenceBundle = null;

      logger.shout("Stopping scheduled tasks");
      atRefreshJob.close();
      for (final t in _compactionTimers) {
        t.cancel();
      }
      _compactionTimers.clear();
      _isRunning = false;
    } on Exception catch (e) {
      throw AtServerException(
          'Caught exception while trying to stop secondary server :${e.toString()}');
    }
  }

  /// The inbound and outbound connection metrics.
  @override
  ConnectionMetrics getMetrics() {
    throw Exception("AtSecondaryServer.getMetrics() is obsolete");
  }

  /// Plants the CRAM activation secret into [keyValueStore] for first-time
  /// activation, only when it has not been deleted, is not already present,
  /// and a non-empty [sharedSecret] was supplied.
  @visibleForTesting
  Future<void> plantCramSecretIfRequired(
      AtKeyValueStore<String, AtData, AtMetaData?> keyValueStore,
      String? sharedSecret) async {
    final cramSecretDeleted =
        await keyValueStore.exists(AtConstants.atCramSecretDeleted);
    final cramSecretExists =
        await keyValueStore.exists(AtConstants.atCramSecret);
    if (!cramSecretDeleted && !cramSecretExists) {
      if (sharedSecret != null && sharedSecret.isNotEmpty) {
        await keyValueStore.put(
            AtConstants.atCramSecret, AtData()..data = sharedSecret);
      } else {
        logger.info('Not planting CRAM secret: no shared_secret supplied and'
            ' none already present');
      }
    }
  }

  /// Initializes the [AtKeyValueStore], [AtCommitLog],
  /// [AtNotificationKeystore] and [AtAccessLog] instances.
  Future<void> _initializePersistentInstances() async {
    AtNotification.defaultTtl =
        Duration(minutes: AtSecondaryConfig.notificationExpiryInMins);

    final atSign = serverContext!.currentAtSign!;
    final targetBackend = PersistenceBackendManager.configuredBackend;

    // NOTE when the on-disk marker disagrees with the configured backend,
    // migrate, verify, then flip, before opening the target.
    await PersistenceBackendManager.migrateIfNeeded(atSign, targetBackend);

    if (targetBackend != PersistenceBackendManager.hive) {
      persistenceFactory = PersistenceBackendManager.factoryFor(targetBackend);
    }
    final config = PersistenceBackendManager.configFor(targetBackend);

    final bundle = await persistenceFactory.initialize(atSign, config);
    _persistenceBundle = bundle;

    _assertServerCapabilities(bundle);

    commitLog = bundle.keyValueStore.commitLog!;
    accessLog = bundle.accessLog!;
    notificationKeystore = bundle.notificationKeystore!;
    keyValueStore = bundle.keyValueStore;

    serverContext!.isKeyStoreInitialized = true;

    await plantCramSecretIfRequired(keyValueStore, serverContext!.sharedSecret);
    if (!await keyValueStore.exists(AtConstants.atSigningKeypairGenerated)) {
      var rsaKeypair = RSAKeypair.fromRandom();
      await keyValueStore.put('${AtConstants.atSigningPublicKey}$currentAtSign',
          AtData()..data = rsaKeypair.publicKey.toString());
      await keyValueStore.put(
          '$currentAtSign:${AtConstants.atSigningPrivateKey}$currentAtSign',
          AtData()..data = rsaKeypair.privateKey.toString());
      await keyValueStore.put(
          AtConstants.atSigningKeypairGenerated, AtData()..data = 'true');
      logger.info('signing keypair generated');
    }
    try {
      var signingPrivateKey = await keyValueStore.get(
          '$currentAtSign:${AtConstants.atSigningPrivateKey}$currentAtSign');
      signingKey = signingPrivateKey?.data;
    } on KeyNotFoundException {
      logger.info(
          'signing key generated? ${await keyValueStore.exists(AtConstants.atSigningKeypairGenerated)}');
    }
  }

  /// Confirms the bundle was initialised with the capabilities a server
  /// requires: access log and notification keystore.
  void _assertServerCapabilities(AtPersistenceBundle bundle) {
    if (bundle.accessLog == null) {
      throw StateError('Server bundle is missing the access log capability. '
          'Did the config disable enableAccessLog?');
    }
    if (bundle.notificationKeystore == null) {
      throw StateError(
          'Server bundle is missing the notification keystore capability. '
          'Did the config disable enableNotificationKeystore?');
    }
    if (bundle.keyValueStore.commitLog == null) {
      throw StateError(
          'Server bundle is missing the commit log on its keystore. '
          'Did the config disable enableCommitId?');
    }
  }

  Future<void> removeMalformedKeys() async {
    if (AtSecondaryConfig.shouldRemoveMalformedKeys) {
      List<String> malformedKeys = AtSecondaryConfig.malformedKeysList;
      List<String> keys = await (await keyValueStore.getKeys()).toList();
      logger.finest('malformed keys from config: $malformedKeys');
      for (String key in keys) {
        if (key.startsWith('public:cached:') || (malformedKeys.contains(key))) {
          try {
            int? commitId = await keyValueStore.remove(key);
            logger.warning('commitId for removed key $key: $commitId');
          } on KeyNotFoundException catch (e) {
            logger
                .severe('Exception in removing malformed key: ${e.toString()}');
          }
        }
      }
    }
  }

  @override
  void pause() {
    _isPaused = true;
  }

  @override
  void resume() {
    _isPaused = false;
  }
}
