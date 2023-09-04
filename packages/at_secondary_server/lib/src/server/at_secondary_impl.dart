// ignore_for_file: prefer_typing_uninitialized_variables

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_refresh_job.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/stream_manager.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/notification/resource_manager.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_certificate_validation.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_update_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_secondary/src/verb/metrics/metrics_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:crypton/crypton.dart';
import 'package:uuid/uuid.dart';
import 'package:meta/meta.dart';

/// [AtSecondaryServerImpl] is a singleton class which implements [AtSecondaryServer]
class AtSecondaryServerImpl implements AtSecondaryServer {
  static final bool? useTLS = AtSecondaryConfig.useTLS;
  static final AtSecondaryServerImpl _singleton =
      AtSecondaryServerImpl._internal();
  static final inboundConnectionFactory =
      InboundConnectionManager.getInstance();
  static final String? storagePath = AtSecondaryConfig.storagePath;
  static final String? commitLogPath = AtSecondaryConfig.commitLogPath;
  static final String? accessLogPath = AtSecondaryConfig.accessLogPath;
  static final String? notificationStoragePath =
      AtSecondaryConfig.notificationStoragePath;
  static final int? expiringRunFreqMins = AtSecondaryConfig.expiringRunFreqMins;
  static final int? commitLogCompactionFrequencyMins =
      AtSecondaryConfig.commitLogCompactionFrequencyMins;
  static final int? commitLogCompactionPercentage =
      AtSecondaryConfig.commitLogCompactionPercentage;
  static final int? commitLogExpiryInDays =
      AtSecondaryConfig.commitLogExpiryInDays;
  static final int? commitLogSizeInKB = AtSecondaryConfig.commitLogSizeInKB;
  static final int? accessLogCompactionFrequencyMins =
      AtSecondaryConfig.accessLogCompactionFrequencyMins;
  static final int? accessLogCompactionPercentage =
      AtSecondaryConfig.accessLogCompactionPercentage;
  static final int? accessLogExpiryInDays =
      AtSecondaryConfig.accessLogExpiryInDays;
  static final int? accessLogSizeInKB = AtSecondaryConfig.accessLogSizeInKB;
  static final bool? clientCertificateRequired =
      AtSecondaryConfig.clientCertificateRequired;

  late SecondaryAddressFinder secondaryAddressFinder;
  late OutboundClientManager outboundClientManager;

  late bool _isPaused;

  var logger = AtSignLogger('AtSecondaryServer');

  factory AtSecondaryServerImpl.getInstance() {
    return _singleton;
  }

  AtSecondaryServerImpl._internal() {
    secondaryAddressFinder = CacheableSecondaryAddressFinder(
        AtSecondaryConfig.rootServerUrl, AtSecondaryConfig.rootServerPort);
    outboundClientManager = OutboundClientManager(secondaryAddressFinder);
  }

  dynamic _serverSocket;
  bool _isRunning = false;
  var currentAtSign;
  var _commitLog;
  var _accessLog;
  var signingKey;
  AtSecondaryContext? serverContext;
  VerbExecutor? executor;
  VerbHandlerManager? verbHandlerManager;
  late AtCacheRefreshJob atRefreshJob;
  late AtCacheManager cacheManager;
  late var commitLogCompactionJobInstance;
  late var accessLogCompactionJobInstance;
  late var notificationKeyStoreCompactionJobInstance;
  @visibleForTesting
  AtCertificateValidationJob? certificateReloadJob;
  @visibleForTesting
  late SecondaryPersistenceStore secondaryPersistenceStore;
  late SecondaryKeyStore<String, AtData?, AtMetaData?> secondaryKeyStore;
  late ResourceManager notificationResourceManager;
  late var atCommitLogCompactionConfig;
  late var atAccessLogCompactionConfig;
  late var atNotificationCompactionConfig;

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

    currentAtSign = AtUtils.fixAtSign(serverContext!.currentAtSign!);
    logger.info('currentAtSign : $currentAtSign');

    // Initialize persistent storage
    await _initializePersistentInstances();

    if (!serverContext!.isKeyStoreInitialized) {
      throw AtServerException('Secondary keystore is not initialized');
    }

    secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(currentAtSign)!;

    //Commit Log Compaction
    commitLogCompactionJobInstance =
        AtCompactionJob(_commitLog, secondaryPersistenceStore);
    atCommitLogCompactionConfig = AtCompactionConfig()
      ..compactionPercentage = commitLogCompactionPercentage
      ..compactionFrequencyInMins = commitLogCompactionFrequencyMins!;
    await commitLogCompactionJobInstance
        .scheduleCompactionJob(atCommitLogCompactionConfig);

    //Access Log Compaction
    accessLogCompactionJobInstance =
        AtCompactionJob(_accessLog, secondaryPersistenceStore);
    atAccessLogCompactionConfig = AtCompactionConfig()
      ..compactionPercentage = accessLogCompactionPercentage!
      ..compactionFrequencyInMins = accessLogCompactionFrequencyMins!;
    await accessLogCompactionJobInstance
        .scheduleCompactionJob(atAccessLogCompactionConfig);

    // Notification keystore compaction
    notificationKeyStoreCompactionJobInstance = AtCompactionJob(
        AtNotificationKeystore.getInstance(), secondaryPersistenceStore);
    atNotificationCompactionConfig = AtCompactionConfig()
      ..compactionPercentage =
          AtSecondaryConfig.notificationKeyStoreCompactionPercentage!
      ..compactionFrequencyInMins =
          AtSecondaryConfig.notificationKeyStoreCompactionFrequencyMins!;
    await notificationKeyStoreCompactionJobInstance
        .scheduleCompactionJob(atNotificationCompactionConfig);

    outboundClientManager.poolSize = serverContext!.outboundConnectionLimit;

    // Refresh Cached Keys
    cacheManager = AtCacheManager(serverContext!.currentAtSign!,
        secondaryKeyStore, outboundClientManager);

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

    // We may have had a VerbHandlerManager set via setVerbHandlerManager()
    // But if not, create a DefaultVerbHandlerManager
    if (verbHandlerManager == null) {
      verbHandlerManager = DefaultVerbHandlerManager(
          secondaryKeyStore,
          outboundClientManager,
          cacheManager,
          StatsNotificationService.getInstance(),
          NotificationManager.getInstance());
    } else {
      // If the server has been stop()'d and re-start()'d then we will get here.
      // We have to make sure that if we used a DefaultVerbHandlerManager then we
      // create a new one here so that it has the correct instances of the SecondaryKeyStore,
      // OutboundClientManager and AtCacheManager
      if (verbHandlerManager is DefaultVerbHandlerManager) {
        verbHandlerManager = DefaultVerbHandlerManager(
            secondaryKeyStore,
            outboundClientManager,
            cacheManager,
            StatsNotificationService.getInstance(),
            NotificationManager.getInstance());
      }
    }

    // Certificate reload
    // We are only ever creating ONE of these jobs in the server - i.e. reusing the same instance
    // across soft restarts
    if (certificateReloadJob == null) {
      certificateReloadJob = AtCertificateValidationJob(
          this,
          AtSecondaryConfig.certificateChainLocation!
              .replaceAll('fullchain.pem', 'restart'),
          AtSecondaryConfig.isForceRestart!);
      await certificateReloadJob!.start();

      // setting checkCertificateReload to true will trigger a check (and restart if required)
      AtSecondaryConfig.subscribe(ModifiableConfigs.checkCertificateReload)
          ?.listen((newValue) async {
        //parse bool from string
        if (newValue.toString() == 'true') {
          unawaited(certificateReloadJob!.checkAndRestartIfRequired());
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

    // Initialize inbound factory and outbound manager
    inboundConnectionFactory.init(serverContext!.inboundConnectionLimit);

    // Notification job
    notificationResourceManager = ResourceManager.getInstance();
    notificationResourceManager.outboundConnectionLimit =
        serverContext!.outboundConnectionLimit;
    notificationResourceManager.start();

    // Starts StatsNotificationService to keep monitor connections alive
    await StatsNotificationService.getInstance().schedule(currentAtSign);

    //initializes subscribers for dynamic config change 'config:Set'
    if (AtSecondaryConfig.testingMode) {
      await initDynamicConfigListeners();
    }

    // clean up malformed keys from keystore
    await removeMalformedKeys();

    try {
      _isRunning = true;
      if (useTLS!) {
        await _startSecuredServer();
      } else {
        await _startUnSecuredServer();
      }
    } on Exception catch (e, stacktrace) {
      _isRunning = false;
      logger.severe('AtSecondaryServer().start exception: ${e.toString()}');
      logger.severe(stacktrace);
      throw AtServerException(e.toString());
    } catch (error, stacktrace) {
      _isRunning = false;
      logger.severe('AtSecondaryServer().start error: ${error.toString()}');
      logger.severe(stacktrace);
      throw AtServerException(error.toString());
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

    resume();
  }

  ///restarts compaction with new compaction frequency. Works only when testingMode set to true.
  Future<void> restartCompaction(
      AtCompactionJob atCompactionJob,
      AtCompactionConfig atCompactionConfig,
      int newFrequency,
      AtLogType atLogType) async {
    if (AtSecondaryConfig.testingMode) {
      logger.finest(
          'Received new frequency for $atLogType compaction: $newFrequency');
      await atCompactionJob.stopCompactionJob();
      logger.finest('Existing cron job of $atLogType compaction terminated');
      atCompactionConfig.compactionFrequencyInMins = newFrequency;
      atCompactionJob.scheduleCompactionJob(atCompactionConfig);
      logger.finest('New compaction cron job started for $atLogType');
    }
  }

  Future<void> initDynamicConfigListeners() async {
    //only works if testingMode is set to true
    if (AtSecondaryConfig.testingMode) {
      logger.warning(
          'UNSAFE: testingMode in config.yaml is set to true. Please set to false if not required.');

      //subscriber for inbound_max_limit change
      logger.finest('Subscribing to dynamic changes made to inbound_max_limit');
      AtSecondaryConfig.subscribe(ModifiableConfigs.inboundMaxLimit)
          ?.listen((newSize) {
        inboundConnectionFactory.init(newSize, isColdInit: false);
        logger.finest(
            'inbound_max_limit change received. Modifying inbound_max_limit of server to $newSize');
      });

      //subscriber for notification keystore compaction freq change
      logger.finest(
          'Subscribing to dynamic changes made to notificationKeystoreCompactionFreq');
      AtSecondaryConfig.subscribe(
              ModifiableConfigs.notificationKeyStoreCompactionFrequencyMins)
          ?.listen((newFrequency) async {
        await restartCompaction(
            notificationKeyStoreCompactionJobInstance,
            atNotificationCompactionConfig,
            newFrequency,
            AtNotificationKeystore.getInstance());
      });

      //subscriber for access log compaction frequency change
      logger.finest(
          'Subscribing to dynamic changes made to accessLogCompactionFreq');
      AtSecondaryConfig.subscribe(
              ModifiableConfigs.accessLogCompactionFrequencyMins)
          ?.listen((newFrequency) async {
        await restartCompaction(accessLogCompactionJobInstance,
            atAccessLogCompactionConfig, newFrequency, _accessLog);
      });

      //subscriber for commit log compaction frequency change
      logger.finest(
          'Subscribing to dynamic changes made to commitLogCompactionFreq');
      AtSecondaryConfig.subscribe(
              ModifiableConfigs.commitLogCompactionFrequencyMins)
          ?.listen((newFrequency) async {
        await restartCompaction(commitLogCompactionJobInstance,
            atCommitLogCompactionConfig, newFrequency, _commitLog);
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

      //subscriber for maxNotificationRetries count change
      logger.finest('Subscribing to dynamic changes made to max_retries');
      AtSecondaryConfig.subscribe(ModifiableConfigs.maxNotificationRetries)
          ?.listen((newCount) {
        logger.finest(
            'Received new value for config \'maxNotificationRetries\': $newCount');
        notificationResourceManager.setMaxRetries(newCount);
        QueueManager.getInstance().setMaxRetries(newCount);
      });

      AtSecondaryConfig.subscribe(ModifiableConfigs.maxRequestsPerTimeFrame)
          ?.listen((maxEnrollRequestsAllowed) {
        AtSecondaryConfig.maxEnrollRequestsAllowed = maxEnrollRequestsAllowed;
      });

      AtSecondaryConfig.subscribe(ModifiableConfigs.timeFrameInMills)
          ?.listen((timeWindowInMills) {
        AtSecondaryConfig.timeFrameInMills = timeWindowInMills;
      });
    }
  }

  /// Listens on the secondary server socket and creates an inbound connection to server socket from client socket
  /// Throws [AtConnection] if unable to create a connection
  /// Throws [SocketException] for exceptions on socket
  /// Throws [Exception] for any other exceptions.
  /// @param - ServerSocket
  void _listen(var serverSocket) {
    logger.finer('serverSocket _listen : ${serverSocket.runtimeType}');
    serverSocket.listen(((clientSocket) {
      var sessionID = '_${Uuid().v4()}';
      InboundConnection? connection;
      try {
        logger.finer(
            'In _listen - clientSocket.peerCertificate : ${clientSocket.peerCertificate}');
        var inBoundConnectionManager = InboundConnectionManager.getInstance();
        connection = inBoundConnectionManager.createConnection(clientSocket,
            sessionId: sessionID);
        connection.acceptRequests(_executeVerbCallBack, _streamCallBack);
        connection.write('@');
      } on InboundConnectionLimitException catch (e) {
        GlobalExceptionHandler.getInstance()
            .handle(e, atConnection: connection, clientSocket: clientSocket);
      }
    }), onError: (error) {
      // We've got no action to take here, let's just log a warning
      logger.warning("ServerSocket.listen called onError with '$error'");
    });
  }

  /// Starts the secondary server in secure mode and calls the listen method of server socket.
  Future<void> _startSecuredServer() async {
    var secCon = SecurityContext();
    var retryCount = 0;
    var certsAvailable = false;
    // if certs are unavailable then retry max 10 minutes
    while (true) {
      try {
        if (certsAvailable || retryCount > 60) {
          break;
        }
        secCon.useCertificateChain(
            serverContext!.securityContext!.publicKeyPath());
        secCon.usePrivateKey(serverContext!.securityContext!.privateKeyPath());
        secCon.setTrustedCertificates(
            serverContext!.securityContext!.trustedCertificatePath());
        certsAvailable = true;
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
      logger.info(
          'Secondary server started on version : ${AtSecondaryConfig.secondaryServerVersion} on root server : ${AtSecondaryConfig.rootServerUrl}');
      logger.info('Secure Socket open for $currentAtSign !');
      _listen(_serverSocket);
    } else {
      logger.severe('certs not available');
    }
  }

  /// Starts the secondary server in un-secure mode and calls the listen method of server socket.
  Future<void> _startUnSecuredServer() async {
    _serverSocket =
        await ServerSocket.bind(InternetAddress.anyIPv4, serverContext!.port);
    logger.info('Unsecure Socket open');
    _listen(_serverSocket);
  }

  ///Accepts the command and the inbound connection and invokes a call to execute method.
  ///@param - command : Command to process
  ///@param - connection : The inbound connection to secondary server from client
  ///Throws [AtConnection] if exceptions occurs in connection.
  ///Throws [InternalServerError] if error occurs in server.
  void _executeVerbCallBack(
      String command, InboundConnection connection) async {
    logger.finer(logger.getAtConnectionLogMessage(
        connection.getMetaData(), 'inside _executeVerbCallBack: $command'));
    try {
      if (_isPaused) {
        await GlobalExceptionHandler.getInstance().handle(
            ServerIsPausedException(
                'Server is temporarily paused and should be available again shortly'),
            atConnection: connection);
        return;
      }

      // We're not paused - let's try to execute the command
      command = SecondaryUtil.convertCommand(command);
      logger.finer('after conversion : $command');
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
    var streamId = sender.getMetaData().streamId;
    logger.finer(logger.getAtConnectionLogMessage(
        sender.getMetaData(), 'stream id:$streamId'));
    if (_isPaused) {
      GlobalExceptionHandler.getInstance().handle(
          ServerIsPausedException(
              'Server is temporarily paused and should be available again shortly'),
          atConnection: sender);
      return;
    }
    if (streamId != null) {
      StreamManager.receiverSocketMap[streamId]!.getSocket().add(data);
    }
  }

  /// Removes all the active connections and stops the secondary server
  /// Throws [AtServerException] if exception occurs in stop the server.
  @override
  Future<void> stop() async {
    pause();
    try {
      logger.info("Executing server stop()");

      //close server socket
      logger.info("Closing ServerSocket");
      _serverSocket.close();

      logger.info("Stopping StatsNotificationService");
      await StatsNotificationService.getInstance().cancel();

      logger.info("Terminating all inbound connections");
      inboundConnectionFactory.removeAllConnections();

      logger.info("Stopping Notification Resource Manager");
      notificationResourceManager.stop();

      logger.info("Closing CommitLog");
      await AtCommitLogManagerImpl.getInstance().close();
      logger.info("Closing AccessLog");
      await AtAccessLogManagerImpl.getInstance().close();
      logger.info("Closing NotificationKeyStore");
      await AtNotificationKeystore.getInstance().close();
      logger.info("Closing SecondaryKeyStore");
      await SecondaryPersistenceStoreFactory.getInstance().close();

      logger.info("Stopping scheduled tasks");
      atRefreshJob.close();
      commitLogCompactionJobInstance.close();
      accessLogCompactionJobInstance.close();
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

  /// Initializes [SecondaryKeyStore], [AtCommitLog], [AtNotificationKeystore] and [AtAccessLog] instances.
  Future<void> _initializePersistentInstances() async {
    // Initialize commit log
    _commitLog = await AtCommitLogManagerImpl.getInstance().getCommitLog(
        serverContext!.currentAtSign!,
        commitLogPath: commitLogPath);
    LastCommitIDMetricImpl.getInstance().atCommitLog = _commitLog;
    _commitLog!.addEventListener(
        CommitLogCompactionService(_commitLog.commitLogKeyStore));

    // Initialize access log
    var atAccessLog = await AtAccessLogManagerImpl.getInstance().getAccessLog(
        serverContext!.currentAtSign!,
        accessLogPath: accessLogPath);
    _accessLog = atAccessLog;

    // Initialize notification storage
    var notificationKeystore = AtNotificationKeystore.getInstance();
    notificationKeystore.currentAtSign = serverContext!.currentAtSign!;
    await notificationKeystore.init(notificationStoragePath!);
    // Loads the notifications into Map.
    await NotificationUtil.loadNotificationMap();

    // Initialize Secondary Storage
    var secondaryPersistenceStore =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore(serverContext!.currentAtSign)!;
    var manager = secondaryPersistenceStore.getHivePersistenceManager()!;
    await manager.init(storagePath!);
    // expiringRunFreqMins default is 10 mins. Randomly run the task every 8-15 mins.
    final expiryRunRandomMins =
        (expiringRunFreqMins! - 2) + Random().nextInt(8);
    logger.finest('Scheduling key expiry job every $expiryRunRandomMins mins');
    manager.scheduleKeyExpireTask(expiryRunRandomMins);

    var atData = AtData();
    atData.data = serverContext!.sharedSecret;
    var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(serverContext!.currentAtSign)!
        .getSecondaryKeyStoreManager()!;
    secondaryKeyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(serverContext!.currentAtSign)!
        .getSecondaryKeyStore()!;
    secondaryKeyStore.commitLog = _commitLog;
    await _initializeAtKeyMetadataStore();
    keyStoreManager.keyStore = secondaryKeyStore;
    // Initialize the hive store
    await secondaryKeyStore.initialize();
    serverContext!.isKeyStoreInitialized = true;
    var keyStore = keyStoreManager.getKeyStore();
    if (!keyStore.isKeyExists(AT_CRAM_SECRET_DELETED)) {
      await keyStore.put(AT_CRAM_SECRET, atData);
    }
    if (!keyStore.isKeyExists(AT_SIGNING_KEYPAIR_GENERATED)) {
      var rsaKeypair = RSAKeypair.fromRandom();
      await keyStore.put('$AT_SIGNING_PUBLIC_KEY$currentAtSign',
          AtData()..data = rsaKeypair.publicKey.toString());
      await keyStore.put('$currentAtSign:$AT_SIGNING_PRIVATE_KEY$currentAtSign',
          AtData()..data = rsaKeypair.privateKey.toString());
      await keyStore.put(AT_SIGNING_KEYPAIR_GENERATED, AtData()..data = 'true');
      logger.info('signing keypair generated');
    }
    try {
      var signingPrivateKey = await keyStore
          .get('$currentAtSign:$AT_SIGNING_PRIVATE_KEY$currentAtSign');
      signingKey = signingPrivateKey?.data;
    } on KeyNotFoundException {
      logger.info(
          'signing key generated? ${keyStore.isKeyExists(AT_SIGNING_KEYPAIR_GENERATED)}');
    }
    await keyStore.deleteExpiredKeys();
  }

  Future<void> _initializeAtKeyMetadataStore() async {
    AtKeyServerMetadataStoreImpl atKeyMetadataStoreImpl =
        AtKeyServerMetadataStoreImpl(serverContext!.currentAtSign!);
    await atKeyMetadataStoreImpl.init(AtSecondaryConfig.atKeyMetadataStore);
    (secondaryKeyStore.commitLog as AtCommitLog)
        .commitLogKeyStore
        .atKeyMetadataStore = atKeyMetadataStoreImpl;

    // Inside "loadDataIntoKeystore" after populating the existing data into
    // the at_metadata_store, insert a dummy key "existing_data_populated"
    // to prevent inserting the data on the subsequent server restart.
    if (atKeyMetadataStoreImpl.contains('existing_data_populated')) {
      return;
    }

    Map<int, CommitEntry> commitEntriesMap =
        await (secondaryKeyStore.commitLog as AtCommitLog)
            .commitLogKeyStore
            .toMap();
    await atKeyMetadataStoreImpl
        .loadDataIntoKeystore(commitEntriesMap.values.toList());
  }

  Future<void> removeMalformedKeys() async {
    // The below code removes the invalid keys on server start-up
    // Intended to remove only keys that starts with "public:cached:" or key is "public:publickey"
    // Fix for the git issue: https://github.com/atsign-foundation/at_server/issues/865

    // [AtSecondaryConfig.shouldRemoveMalformedKeys] is set to true by default.
    // To retain the invalid keys on server start-up, set the flag to false.
    if (AtSecondaryConfig.shouldRemoveMalformedKeys) {
      List<String> malformedKeys = AtSecondaryConfig.malformedKeysList;
      final keyStore = secondaryPersistenceStore.getSecondaryKeyStore()!;
      List<String> keys = keyStore.getKeys();
      logger.finest('malformed keys from config: $malformedKeys');
      for (String key in keys) {
        if (key.startsWith('public:cached:') || (malformedKeys.contains(key))) {
          try {
            int? commitId = await keyStore.remove(key);
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
