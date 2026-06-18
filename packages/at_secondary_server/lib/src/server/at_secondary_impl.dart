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
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/server/verb_handler_context.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:crypton/crypton.dart';
import 'package:meta/meta.dart';

import 'http_request_handler.dart';

/// [AtSecondaryServerImpl] is a singleton class which implements [AtSecondaryServer]
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

  /// Builds the per-atSign persistence stores during [start] and tears
  /// them down during [stop]. Defaults to a [HiveAtPersistenceFactory];
  /// tests / alternative deployments can replace it before calling
  /// [start]. Made public so tests can inject a stand-in (e.g.
  /// `TestAtPersistenceFactory`).
  AtPersistenceFactory persistenceFactory = HiveAtPersistenceFactory();

  /// The bundle this server is currently running against. Set during
  /// [_initializePersistentInstances]; used by [start] for
  /// scheduleKeyExpireTask and by [stop] to close.
  AtPersistenceBundle? _persistenceBundle;

  factory AtSecondaryServerImpl.getInstance() {
    return _singleton;
  }

  AtSecondaryServerImpl._internal() {
    logger.shout('executableArguments: ${Platform.executableArguments}');
    logger.shout('DART_VM_OPTIONS: ${Platform.environment['DART_VM_OPTIONS']}');

    // TODO There's a whole lifecycle mess here that needs to be cleaned up
    // at some point. Currently we create this singleton which then has a
    // lifecycle where it can be started and stopped. When it is started, all
    // of its relevant state is recreated, since things (e.g. ssl certs) may
    // have changed. When it is stopped, all relevant state is cleared.
    // This should not be a singleton, and state management should be
    // 'stop the current server; create new instance; start new instance'.
    // Doing this will be a massive chunk of busywork.
    // NB: These specific instance variables are depended on by unit tests
    // so they are initialized here, but are also initialized as part of the
    // `start()` function
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

  /// Timers driving the per-resource compaction cron. Each ticks
  /// on its own configured frequency; tick body drains the
  /// resource's `compact(false)` stream with an overlap guard.
  final List<Timer> _compactionTimers = [];

  /// One-shot timer driving the key-expiry sweep, rescheduled after
  /// every sweep from [AtKeyValueStore.nextExpiresAt] — the server
  /// sleeps until the next key actually expires instead of polling
  /// on a fixed cadence. Owned by the secondary (not the
  /// persistence layer): the application picks the schedule, the
  /// keystore exposes [AtKeyValueStore.nextExpiresAt] and
  /// [AtKeyValueStore.deleteExpiredKeys].
  Timer? _keyExpiryTimer;

  /// Floor for the expiry-sweep sleep — stops a burst of
  /// near-future expiries from re-running the sweep back-to-back.
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

  /// Check various parameters required to start the secondary server. Invokes call to [_startSecuredServer] to start secondary server in secure mode and
  /// [_startUnSecuredServer] to start secondary server in un-secure mode.
  /// Throws [AtServerException] if exception occurs in starting the secondary server.
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

    // We used to check at this stage that a verbHandlerManager was set
    // but now we don't, as if it's not set we will create a DefaultVerbHandlerManager

    if (useTLS! && serverContext!.securityContext == null) {
      throw AtServerException('Security context is not set');
    }

    if (serverContext!.currentAtSign == null) {
      throw AtServerException('User atSign is not set');
    }

    currentAtSign = serverContext!.currentAtSign!.toAtsign();
    logger.shout('start(): currentAtSign : $currentAtSign');

    // Initialize persistent storage
    await _initializePersistentInstances();

    if (!serverContext!.isKeyStoreInitialized) {
      throw AtServerException('Secondary keystore is not initialized');
    }

    // Initialize enrollment manager
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

    // Set up removal of expired keys
    // We add a hook here to handle deletion of enrollments.
    keyValueStore.preRemoveHooks.add(enrollmentManager.preRemoveHook);

    // Startup sweep, then schedule the next one from
    // nextExpiresAt() — see _scheduleNextExpirySweep for the
    // sleep-until-next-expiry shape and its staleness bound.
    await keyValueStore.deleteExpiredKeys();
    await _scheduleNextExpirySweep();

    // Compaction is scheduled at the secondary level (not by the
    // persistence layer): the Timer ticks, drains the resource's
    // compact(false) stream with an overlap guard, and records
    // primitives to a stats service.
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

    // Refresh Cached Keys
    cacheManager = AtCacheManager(serverContext!.currentAtSign!, keyValueStore,
        outboundClientManager, notificationManager);

    var random = Random();
    var runRefreshJobHour = random.nextInt(23);
    atRefreshJob =
        AtCacheRefreshJob(serverContext!.currentAtSign!, cacheManager);
    atRefreshJob.scheduleRefreshJob(runRefreshJobHour);

    // setting doCacheRefresh to true will trigger an immediate run of the cache refresh job
    AtSecondaryConfig.subscribe(ModifiableConfigs.doCacheRefreshNow)
        ?.listen((newValue) async {
      //parse bool from string
      if (newValue.toString() == 'true') {
        unawaited(atRefreshJob.refreshNow());
      }
    });

    // Build the verb-handler context: server-scoped collaborators injected into
    // every verb handler at construction time (replacing singleton reaches).
    final verbHandlerContext = VerbHandlerContext(
      currentAtSign: currentAtSign,
      responseManager: DefaultResponseHandlerManager(),
    );

    // We may have had a VerbHandlerManager set via setVerbHandlerManager()
    // But if not, create a DefaultVerbHandlerManager
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
        context: verbHandlerContext,
      );
    } else {
      // If the server has been stop()'d and re-start()'d then we will get here.
      // We have to make sure that if we used a DefaultVerbHandlerManager then we
      // create a new one here so that it has the correct instances of the AtKeyValueStore,
      // OutboundClientManager and AtCacheManager
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
          context: verbHandlerContext,
        );
      }
    }

    // Certificate reload
    // We are only ever creating ONE of these jobs in the server - i.e. reusing the same instance
    // across soft restarts
    if (certificateReloadJob == null) {
      certificateReloadJob = AtCertificateValidationJob(
          this,
          AtSecondaryConfig.certificateChainLocation
              .replaceAll('fullchain.pem', 'restart'),
          AtSecondaryConfig.isForceRestart);
      await certificateReloadJob!.start();

      // setting checkCertificateReload to true will trigger a check (and restart if required)
      AtSecondaryConfig.subscribe(ModifiableConfigs.checkCertificateReload)
          ?.listen((newValue) async {
        //parse bool from string
        if (newValue.toString() == 'true') {
          unawaited(certificateReloadJob!
              .checkAndRestartIfRequired(forceRestartThisTime: true));
        }
      });

      // setting checkCertificateReload to true will trigger a check (and restart if required)
      AtSecondaryConfig.subscribe(ModifiableConfigs.shouldReloadCertificates)
          ?.listen((newValue) async {
        //parse bool from string
        if (newValue.toString() == 'true') {
          await certificateReloadJob!.createRestartFile();
        } else if (newValue.toString() == 'false') {
          await certificateReloadJob!.deleteRestartFile();
        }
      });
    }
    // We're currently in process of restarting, so we can delete the file which triggers restarts
    await certificateReloadJob!.deleteRestartFile();

    inboundConnectionManager = InboundConnectionManager(
        serverAtSign: currentAtSign,
        poolSize: serverContext!.inboundConnectionLimit);

    // Starts StatsNotificationService to keep monitor connections alive
    await statsNotificationService.schedule(currentAtSign, commitLog);

    //initializes subscribers for dynamic config change 'config:Set'
    await initDynamicConfigListeners();

    // clean up malformed keys from keystore
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
        // waiting a few milliseconds to allow the server socket to finish its initialization
        await Future.delayed(Duration(milliseconds: 100));
        await stop();
      } catch (e) {
        logger.severe('Caught exception $e in server stop()');
      }
      logger.warning('Training mode set - exiting');
      exit(0);
    }

    // Enqueue any undelivered notifications for delivery to other atServers
    await notificationManager.reEnqueueUndelivered();

    resume();
  }

  /// Restart compaction with a new frequency for the resource
  /// identified by [label]. Works only when testing mode is set.
  Future<void> _restartCompaction(
    Compactable resource,
    Duration newFrequency,
    String label,
    AtCompactionStatsService statsService,
  ) async {
    logger.finest(
        'Received new frequency for $label compaction: ${newFrequency.inMinutes}m');
    // Cancel any existing timer for this label (best effort: we
    // currently don't index timers by label so the simplest restart
    // is to cancel all and re-schedule the one we care about).
    for (final t in _compactionTimers) {
      t.cancel();
    }
    _compactionTimers.clear();
    _scheduleCompaction(resource, newFrequency, label, statsService);
  }

  /// Computes the next expiry-sweep wake-up from
  /// [AtKeyValueStore.nextExpiresAt] and arms [_keyExpiryTimer].
  ///
  /// Sleep is clamped to `[_minExpirySleep, expiringRunFreqMins]`.
  /// The ceiling matters for correctness, not just hygiene:
  /// `nextExpiresAt()` is a snapshot, and a put with a sooner
  /// expiry while we sleep would otherwise go un-swept until the
  /// (stale) wake-up. Capping the sleep bounds that staleness at
  /// one old-style poll interval — the worst case is exactly
  /// today's fixed-cadence behaviour, the common case is a sweep
  /// within seconds of the next key actually expiring. The same
  /// ceiling doubles as the idle re-check period when no key has
  /// a ttl at all.
  ///
  /// A 0-30s jitter spreads the disk load when multiple co-hosted
  /// atSigns have expiries clustered at the same wall-clock minute.
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
      try {
        await keyValueStore.deleteExpiredKeys();
      } on Exception catch (e) {
        logger.warning('Key expiry sweep failed: $e');
      }
      await _scheduleNextExpirySweep();
    });
  }

  /// Schedule a periodic compaction tick for [resource]. The tick
  /// drains `compact(false)` with an overlap guard and records the
  /// pass via [statsService].
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
    //subscriber for inbound_max_limit change
    logger.finest('Subscribing to dynamic changes made to inbound_max_limit');
    AtSecondaryConfig.subscribe(ModifiableConfigs.inboundMaxLimit)
        ?.listen((newSize) {
      inboundConnectionManager.pool.resize(newSize);
      logger.finest(
          'inbound_max_limit change received. Modifying inbound_max_limit of server to $newSize');
    });

    final statsService = AtCompactionStatsService(keyValueStore);

    //subscriber for notification keystore compaction freq change
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

    //subscriber for access log compaction frequency change
    logger.finest(
        'Subscribing to dynamic changes made to accessLogCompactionFreq');
    AtSecondaryConfig.subscribe(
            ModifiableConfigs.accessLogCompactionFrequencyMins)
        ?.listen((newFrequency) async {
      await _restartCompaction(accessLog, Duration(minutes: newFrequency),
          'accessLog', statsService);
    });

    //subscriber for commit log compaction frequency change
    logger.finest(
        'Subscribing to dynamic changes made to commitLogCompactionFreq');
    AtSecondaryConfig.subscribe(
            ModifiableConfigs.commitLogCompactionFrequencyMins)
        ?.listen((newFrequency) async {
      await _restartCompaction(commitLog, Duration(minutes: newFrequency),
          'commitLog', statsService);
    });

    //subscriber for autoNotify state change
    logger.finest('Subscribing to dynamic changes made to autoNotify');
    late bool autoNotifyState;
    AtSecondaryConfig.subscribe(ModifiableConfigs.autoNotify)
        ?.listen((newValue) {
      //parse bool from string
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

  /// Listens on the secondary server socket and creates an inbound connection to server socket from client socket
  /// Throws [AtConnection] if unable to create a connection
  /// Throws [SocketException] for exceptions on socket
  /// Throws [Exception] for any other exceptions.
  /// @param - ServerSocket
  void _listen(final serverSocket) {
    // ALPN support.
    // First, make a PseudoServerSocket to which we will pass sockets which
    // have a selectedProtocol which is neither null nor 'atProtocol/1.0'.
    // See later in this method for where we pass sockets received on the real
    // serverSocket to the pseudoServerSocket.
    final pseudoServerSocket = PseudoServerSocket(serverSocket);
    // Second, make an HttpServer which is handling sockets which are passed
    // to the pseudoServerSocket
    HttpServer httpServer = HttpServer.listenOn(pseudoServerSocket);
    final httpReqHandler =
        AtServerHttpRequestHandler(currentAtSign, keyValueStore);
    httpServer.listen((HttpRequest req) {
      if (req.uri.path == '/ws') {
        // Upgrade an HttpRequest to a WebSocket connection.
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
        // ALPN support
        // selectedProtocol is neither null nor 'atProtocol/1.0'
        // TODO check specifically for http/1.1
        logger.info('Transferring socket to HttpServer for handling');
        pseudoServerSocket.add(clientSocket);
      }
    }), onError: (error) {
      // We've got no action to take here, let's just log a warning
      logger.warning("ServerSocket.listen called onError with '$error'");
    });
  }

  /// Starts the secondary server in secure mode and calls the listen method of server socket.
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
        // secCon.setAlpnProtocols(['atp/1.0', 'h2', 'http/1.1'], true);
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

  /// Starts the secondary server in un-secure mode and calls the listen method of server socket.
  Future<void> _startUnSecuredServer() async {
    _serverSocket =
        await ServerSocket.bind(InternetAddress.anyIPv4, serverContext!.port);
    logger.shout('Unsecure Socket open');
    _listen(_serverSocket);
  }

  ///Accepts the command and the inbound connection and invokes a call to execute method.
  ///@param - command : Command to process
  ///@param - connection : The inbound connection to secondary server from client
  ///Throws [AtConnection] if exceptions occurs in connection.
  ///Throws [InternalServerError] if error occurs in server.
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

      // We're not paused - let's try to execute the command
      // command = SecondaryUtil.convertCommand(command);
      // logger.finer('after conversion : $command');
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

  /// Removes all the active connections and stops the secondary server
  /// Throws [AtServerException] if exception occurs in stop the server.
  @override
  Future<void> stop() async {
    pause();
    try {
      logger.shout("Executing server stop()");

      //close server socket
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

  /// Gets the inbound connection metrics and outbound connection metrics.
  /// @return: Returns [ConnectionMetrics]
  @override
  ConnectionMetrics getMetrics() {
    throw Exception("AtSecondaryServer.getMetrics() is obsolete");
  }

  /// Initializes [AtKeyValueStore], [AtCommitLog], [AtNotificationKeystore] and [AtAccessLog] instances.
  Future<void> _initializePersistentInstances() async {
    AtNotification.defaultTtl =
        Duration(minutes: AtSecondaryConfig.notificationExpiryInMins);

    final config = HivePersistenceConfig.serverDefaults(
      storagePath: AtSecondaryConfig.storagePath,
      commitLogPath: AtSecondaryConfig.commitLogPath,
      accessLogPath: AtSecondaryConfig.accessLogPath,
      notificationStoragePath: AtSecondaryConfig.notificationStoragePath,
    );
    final bundle = await persistenceFactory.initialize(
        serverContext!.currentAtSign!, config);
    _persistenceBundle = bundle;

    _assertServerCapabilities(bundle);

    // Server bundle invariant: the keystore's commitLog is non-null
    // (asserted above). Bind once to a non-nullable local so
    // downstream consumers don't litter `!` at every call site.
    commitLog = bundle.keyValueStore.commitLog!;
    accessLog = bundle.accessLog!;
    notificationKeystore = bundle.notificationKeystore!;
    keyValueStore = bundle.keyValueStore;

    serverContext!.isKeyStoreInitialized = true;

    var atData = AtData();
    atData.data = serverContext!.sharedSecret;

    // Ensure essential data is present in persistence
    if (!await keyValueStore.exists(AtConstants.atCramSecretDeleted)) {
      await keyValueStore.put(AtConstants.atCramSecret, atData);
    }
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

  /// Confirms that the bundle was initialised with the optional
  /// capabilities a server requires (access log, notification
  /// keystore). The bundle exposes them as nullable to support
  /// client-shaped consumers that don't need them; for a server
  /// they must be present, so missing them is a configuration
  /// bug, not a runtime condition. After this check, the
  /// [accessLog] and [notificationKeystore] fields can be assigned
  /// from the bundle without `!` litter at every call site.
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
    // The below code removes the invalid keys on server start-up
    // Intended to remove only keys that starts with "public:cached:" or key is "public:publickey"
    // Fix for the git issue: https://github.com/atsign-foundation/at_server/issues/865

    // [AtSecondaryConfig.shouldRemoveMalformedKeys] is set to true by default.
    // To retain the invalid keys on server start-up, set the flag to false.
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
