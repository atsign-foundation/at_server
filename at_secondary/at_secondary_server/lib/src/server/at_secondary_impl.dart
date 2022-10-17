// ignore_for_file: prefer_typing_uninitialized_variables

import 'dart:io';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/connection_metrics.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/stream_manager.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_secondary/src/notification/resource_manager.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/refresh/at_refresh_job.dart';
import 'package:at_secondary/src/server/at_certificate_validation.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_secondary/src/verb/metrics/metrics_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:crypton/crypton.dart';
import 'package:uuid/uuid.dart';

/// [AtSecondaryServerImpl] is a singleton class which implements [AtSecondaryServer]
class AtSecondaryServerImpl implements AtSecondaryServer {
  static final bool? useSSL = AtSecondaryConfig.useSSL;
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
  late bool _isPaused;

  var logger = AtSignLogger('AtSecondaryServer');

  factory AtSecondaryServerImpl.getInstance() {
    return _singleton;
  }

  AtSecondaryServerImpl._internal();

  static late var _serverSocket;
  bool _isRunning = false;
  var currentAtSign;
  var _commitLog;
  var _accessLog;
  var signingKey;
  AtSecondaryContext? serverContext;
  VerbExecutor? executor;
  VerbHandlerManager? verbManager;
  late AtRefreshJob atRefreshJob;
  late var commitLogCompactionJobInstance;
  late var accessLogCompactionJobInstance;
  late var notificationKeyStoreCompactionJobInstance;
  late SecondaryPersistenceStore _secondaryPersistenceStore;
  late var atCommitLogCompactionConfig;
  late var atAccessLogCompactionConfig;
  late var atNotificationCompactionConfig;

  @override
  void setExecutor(VerbExecutor executor) {
    this.executor = executor;
  }

  @override
  void setVerbHandlerManager(VerbHandlerManager verbManager) {
    this.verbManager = verbManager;
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
    if (verbManager == null) {
      throw AtServerException('Verb handler manager is not initialized');
    }
    if (useSSL! && serverContext!.securityContext == null) {
      throw AtServerException('Security context is not set');
    }

    if (serverContext!.currentAtSign == null) {
      throw AtServerException('User atSign is not set');
    }

    currentAtSign = AtUtils.formatAtSign(serverContext!.currentAtSign);
    logger.info('currentAtSign : $currentAtSign');

    //Initializing all the hive instances
    await _initializePersistentInstances();

    //Initializing verb handler manager
    DefaultVerbHandlerManager().init();

    if (!serverContext!.isKeyStoreInitialized) {
      throw AtServerException('Secondary keystore is not initialized');
    }

    _secondaryPersistenceStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(currentAtSign)!;

    //Commit Log Compaction
    commitLogCompactionJobInstance =
        AtCompactionJob(_commitLog, _secondaryPersistenceStore);
    atCommitLogCompactionConfig = AtCompactionConfig(
        commitLogSizeInKB!,
        commitLogExpiryInDays!,
        commitLogCompactionPercentage!,
        commitLogCompactionFrequencyMins!);
    await commitLogCompactionJobInstance
        .scheduleCompactionJob(atCommitLogCompactionConfig);

    //Access Log Compaction
    accessLogCompactionJobInstance =
        AtCompactionJob(_accessLog, _secondaryPersistenceStore);
    atAccessLogCompactionConfig = AtCompactionConfig(
        accessLogSizeInKB!,
        accessLogExpiryInDays!,
        accessLogCompactionPercentage!,
        accessLogCompactionFrequencyMins!);
    await accessLogCompactionJobInstance
        .scheduleCompactionJob(atAccessLogCompactionConfig);

    // Notification keystore compaction
    notificationKeyStoreCompactionJobInstance = AtCompactionJob(
        AtNotificationKeystore.getInstance(), _secondaryPersistenceStore);
    atNotificationCompactionConfig = AtCompactionConfig(
        AtSecondaryConfig.notificationKeyStoreSizeInKB!,
        AtSecondaryConfig.notificationKeyStoreExpiryInDays!,
        AtSecondaryConfig.notificationKeyStoreCompactionPercentage!,
        AtSecondaryConfig.notificationKeyStoreCompactionFrequencyMins!);
    await notificationKeyStoreCompactionJobInstance
        .scheduleCompactionJob(atNotificationCompactionConfig);

    // Refresh Cached Keys
    var random = Random();
    var runRefreshJobHour = random.nextInt(23);
    atRefreshJob = AtRefreshJob(serverContext!.currentAtSign);
    atRefreshJob.scheduleRefreshJob(runRefreshJobHour);

    //Certificate reload
    var certificateReload = AtCertificateValidationJob.getInstance();
    await certificateReload.runCertificateExpiryCheckJob();

    // Initialize inbound factory and outbound manager
    inboundConnectionFactory.init(serverContext!.inboundConnectionLimit);

    OutboundClientManager.getInstance()
        .init(serverContext!.outboundConnectionLimit);

    // Notification job
    ResourceManager.getInstance().init(serverContext!.outboundConnectionLimit);

    // Starts StatsNotificationService to keep monitor connections alive
    StatsNotificationService.getInstance().schedule(currentAtSign);

    //initializes subscribers for dynamic config change 'config:Set'
    if (AtSecondaryConfig.testingMode) {
      await initDynamicConfigListeners();
    }

    // clean up malformed keys from keystore
    await _removeMalformedKeys();

    try {
      _isRunning = true;
      if (useSSL!) {
        _startSecuredServer();
      } else {
        _startUnSecuredServer();
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
      atCompactionConfig.compactionFrequencyMins = newFrequency;
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
      AtSecondaryConfig.subscribe(ModifiableConfigs.inbound_max_limit)
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
        restartCompaction(
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
        restartCompaction(accessLogCompactionJobInstance,
            atAccessLogCompactionConfig, newFrequency, _accessLog);
      });

      //subscriber for commit log compaction frequency change
      logger.finest(
          'Subscribing to dynamic changes made to commitLogCompactionFreq');
      AtSecondaryConfig.subscribe(
              ModifiableConfigs.commitLogCompactionFrequencyMins)
          ?.listen((newFrequency) async {
        restartCompaction(commitLogCompactionJobInstance,
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
        UpdateVerbHandler.setAutoNotify(autoNotifyState);
        DeleteVerbHandler.setAutoNotify(autoNotifyState);
        UpdateMetaVerbHandler.setAutoNotify(autoNotifyState);
      });

      //subscriber for maxNotificationRetries count change
      logger.finest('Subscribing to dynamic changes made to max_retries');
      AtSecondaryConfig.subscribe(ModifiableConfigs.maxNotificationRetries)
          ?.listen((newCount) {
        logger.finest(
            'Received new value for config \'maxNotificationRetries\': $newCount');
        ResourceManager.getInstance().setMaxRetries(newCount);
        QueueManager.getInstance().setMaxRetries(newCount);
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
      if (_isPaused) {
        logger.info('Server cannot accept connections now.');
        return;
      }
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
  void _startSecuredServer() {
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
        sleep(Duration(seconds: 10));
      }
    }
    if (certsAvailable) {
      SecureServerSocket.bind(
              InternetAddress.anyIPv4, serverContext!.port, secCon,
              requestClientCertificate: true)
          .then((SecureServerSocket socket) {
        logger.info(
            'Secondary server started on version : ${AtSecondaryConfig.secondaryServerVersion} on root server : ${AtSecondaryConfig.rootServerUrl}');
        logger.info('Secure Socket open for $currentAtSign !');
        _serverSocket = socket;
        _listen(_serverSocket);
      });
    } else {
      logger.severe('certs not available');
    }
  }

  /// Starts the secondary server in un-secure mode and calls the listen method of server socket.
  void _startUnSecuredServer() {
    ServerSocket.bind(InternetAddress.anyIPv4, serverContext!.port)
        .then((ServerSocket socket) {
      logger.info('Unsecure Socket open');
      _serverSocket = socket;
      _listen(_serverSocket);
    });
  }

  ///Accepts the command and the inbound connection and invokes a call to execute method.
  ///@param - command : Command to process
  ///@param - connection : The inbound connection to secondary server from client
  ///Throws [AtConnection] if exceptions occurs in connection.
  ///Throws [InternalServerError] if error occurs in server.
  void _executeVerbCallBack(
      String command, InboundConnection connection) async {
    logger.finer('inside _executeVerbCallBack: $command');
    try {
      command = SecondaryUtil.convertCommand(command);
      await executor!.execute(command, connection, verbManager!);
    } on Exception catch (e) {
      logger.severe(
          'Exception occurred in executing the verb: $command ${e.toString()}');
      await GlobalExceptionHandler.getInstance()
          .handle(e, atConnection: connection);
    } on Error catch (e) {
      logger.severe(
          'Error occurred in executing the verb: $command ${e.toString()}');
      await GlobalExceptionHandler.getInstance()
          .handle(InternalServerError(e.toString()), atConnection: connection);
    }
  }

  void _streamCallBack(List<int> data, InboundConnection sender) {
    var streamId = sender.getMetaData().streamId;
    logger.finer('stream id:$streamId');
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

      logger.info("Terminating all inbound connections");
      inboundConnectionFactory.removeAllConnections();

      logger.info("Closing CommitLog HiveBox");
      await AtCommitLogManagerImpl.getInstance().close();
      logger.info("Closing AccessLog HiveBox");
      await AtAccessLogManagerImpl.getInstance().close();
      logger.info("Closing NotificationKeyStore HiveBox");
      await AtNotificationKeystore.getInstance().close();
      logger.info("Closing Main key store HiveBox");
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
    return ConnectionMetricsImpl();
  }

  /// Initializes [AtCommitLog], [AtAccessLog] and [HivePersistenceManager] instances.
  Future<void> _initializePersistentInstances() async {
    // Initialize commit log
    var atCommitLog = await AtCommitLogManagerImpl.getInstance().getCommitLog(
        serverContext!.currentAtSign!,
        commitLogPath: commitLogPath);
    LastCommitIDMetricImpl.getInstance().atCommitLog = atCommitLog;
    atCommitLog!.addEventListener(
        CommitLogCompactionService(atCommitLog.commitLogKeyStore));

    // Initialize access log
    var atAccessLog = await AtAccessLogManagerImpl.getInstance().getAccessLog(
        serverContext!.currentAtSign!,
        accessLogPath: accessLogPath);
    _accessLog = atAccessLog;

    // Initialize notification storage
    var notificationInstance = AtNotificationKeystore.getInstance();
    notificationInstance.currentAtSign = serverContext!.currentAtSign!;
    await notificationInstance.init(notificationStoragePath!);
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
    var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(serverContext!.currentAtSign)!
        .getSecondaryKeyStore()!;
    hiveKeyStore.commitLog = atCommitLog;
    _commitLog = atCommitLog;
    keyStoreManager.keyStore = hiveKeyStore;
    // Initialize the hive store
    hiveKeyStore.init();
    serverContext!.isKeyStoreInitialized =
        true; //TODO check hive for sample data
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

  Future<void> _removeMalformedKeys() async {
    try {
      List<String> malformedKeys = AtSecondaryConfig.malformedKeysList;
      logger.finest('malformed keys from config: $malformedKeys');
      for (String key in malformedKeys) {
        final keyStore = _secondaryPersistenceStore.getSecondaryKeyStore()!;
        if (keyStore.isKeyExists(key)) {
          int? commitId = await keyStore.remove(key);
          logger.warning('commitId for removed key $key: $commitId');
          // do not sync back the deleted malformed key. remove from commit log if commitId is not null
          if (commitId != null) {
            await _commitLog.commitLogKeyStore.remove(commitId);
          }
        }
      }
    } on Exception catch (e) {
      logger.severe('Exception in removing malformed key: ${e.toString()}');
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
