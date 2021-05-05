import 'dart:io';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/connection_metrics.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/stream_manager.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/notification/resource_manager.dart';
import 'package:at_secondary/src/refresh/at_refresh_job.dart';
import 'package:at_secondary/src/server/at_certificate_validation.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_secondary/src/verb/metrics/metrics_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart';
import 'package:crypton/crypton.dart';
import 'package:uuid/uuid.dart';

/// [AtSecondaryServerImpl] is a singleton class which implements [AtSecondaryServer]
class AtSecondaryServerImpl implements AtSecondaryServer {
  static final bool useSSL = AtSecondaryConfig.useSSL;
  static final AtSecondaryServerImpl _singleton =
      AtSecondaryServerImpl._internal();
  static final inboundConnectionFactory =
      InboundConnectionManager.getInstance();
  static final String storagePath = AtSecondaryConfig.storagePath;
  static final String commitLogPath = AtSecondaryConfig.commitLogPath;
  static final String accessLogPath = AtSecondaryConfig.accessLogPath;
  static final String notificationStoragePath =
      AtSecondaryConfig.notificationStoragePath;
  static final int expiringRunFreqMins = AtSecondaryConfig.expiringRunFreqMins;
  static final int commitLogCompactionFrequencyMins =
      AtSecondaryConfig.commitLogCompactionFrequencyMins;
  static final int commitLogCompactionPercentage =
      AtSecondaryConfig.commitLogCompactionPercentage;
  static final int commitLogExpiryInDays =
      AtSecondaryConfig.commitLogExpiryInDays;
  static final int commitLogSizeInKB = AtSecondaryConfig.commitLogSizeInKB;
  static final int accessLogCompactionFrequencyMins =
      AtSecondaryConfig.accessLogCompactionFrequencyMins;
  static final int accessLogCompactionPercentage =
      AtSecondaryConfig.accessLogCompactionPercentage;
  static final int accessLogExpiryInDays =
      AtSecondaryConfig.accessLogExpiryInDays;
  static final int accessLogSizeInKB = AtSecondaryConfig.accessLogSizeInKB;
  static final int maxNotificationEntries =
      AtSecondaryConfig.maxNotificationEntries;
  static final bool clientCertificateRequired =
      AtSecondaryConfig.clientCertificateRequired;
  bool _isPaused;

  var logger = AtSignLogger('AtSecondaryServer');

  factory AtSecondaryServerImpl.getInstance() {
    return _singleton;
  }

  AtSecondaryServerImpl._internal();

  static var _serverSocket;
  bool _isRunning = false;
  var currentAtSign;
  var _commitLog;
  var _accessLog;
  var signingKey;
  AtSecondaryContext serverContext;
  VerbExecutor executor;
  VerbHandlerManager verbManager;
  AtRefreshJob atRefreshJob;
  var commitLogCompactionJobInstance;
  var accessLogCompactionJobInstance;

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
    serverContext = context;
  }

  @override
  bool isRunning() {
    logger.info('Checking whether server is running or not');
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
    if (useSSL && serverContext.securityContext == null) {
      throw AtServerException('Security context is not set');
    }

    if (serverContext.port == null) {
      throw AtServerException('Secondary port is not set');
    }

    if (serverContext.currentAtSign == null) {
      throw AtServerException('User atSign is not set');
    }

    currentAtSign = AtUtils.formatAtSign(serverContext.currentAtSign);
    logger.info('currentAtSign : $currentAtSign');

    //Initializing all the hive instances
    await _initializeHiveInstances();

    //Initializing verb handler manager
    DefaultVerbHandlerManager().init();

    if (!serverContext.isKeyStoreInitialized) {
      throw AtServerException('Secondary keystore is not initialized');
    }

    //Commit Log Compaction
    commitLogCompactionJobInstance = AtCompactionJob(_commitLog);
    var atCommitLogCompactionConfig = AtCompactionConfig(
        commitLogSizeInKB,
        commitLogExpiryInDays,
        commitLogCompactionPercentage,
        commitLogCompactionFrequencyMins);
    await commitLogCompactionJobInstance
        .scheduleCompactionJob(atCommitLogCompactionConfig);

    //Access Log Compaction
    accessLogCompactionJobInstance = AtCompactionJob(_accessLog);
    var atAccessLogCompactionConfig = AtCompactionConfig(
        accessLogSizeInKB,
        accessLogExpiryInDays,
        accessLogCompactionPercentage,
        accessLogCompactionFrequencyMins);
    await accessLogCompactionJobInstance
        .scheduleCompactionJob(atAccessLogCompactionConfig);

    // Refresh Cached Keys
    var random = Random();
    var runRefreshJobHour = random.nextInt(23);
    atRefreshJob = AtRefreshJob(serverContext.currentAtSign);
    atRefreshJob.scheduleRefreshJob(runRefreshJobHour);

    //Certificate reload
    var certificateReload = AtCertificateValidationJob.getInstance();
    await certificateReload.runCertificateExpiryCheckJob();

    // Notification job
    var resourceManager = ResourceManager.getInstance();
    if (!resourceManager.isRunning) {
      resourceManager.schedule();
    }

    // Initialize inbound factory and outbound manager
    inboundConnectionFactory.init(serverContext.inboundConnectionLimit);
    OutboundClientManager.getInstance()
        .init(serverContext.outboundConnectionLimit);

    try {
      _isRunning = true;
      if (useSSL) {
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
    resume();
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
      var _sessionID = '_' + Uuid().v4();
      var connection;
      try {
        logger.finer(
            'In _listen - clientSocket.peerCertificate : ${clientSocket.peerCertificate}');
        var inBoundConnectionManager = InboundConnectionManager.getInstance();
        connection = inBoundConnectionManager.createConnection(clientSocket,
            sessionId: _sessionID);
        connection.acceptRequests(_executeVerbCallBack, _streamCallBack);
        connection.write('@');
      } on InboundConnectionLimitException catch (e) {
        GlobalExceptionHandler.getInstance()
            .handle(e, atConnection: connection, clientSocket: clientSocket);
      }
    }), onError: (error) {
      logger.severe(error);
      GlobalExceptionHandler.getInstance()
          .handle(InternalServerError(error.toString()));
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
        secCon
            .useCertificateChain(serverContext.securityContext.publicKeyPath());
        secCon.usePrivateKey(serverContext.securityContext.privateKeyPath());
        secCon.setTrustedCertificates(
            serverContext.securityContext.trustedCertificatePath());
        certsAvailable = true;
      } on FileSystemException catch (e) {
        retryCount++;
        logger.info('certs unavailable. Retry count ${retryCount}');
      }
      sleep(Duration(seconds: 10));
    }
    if (certsAvailable) {
      SecureServerSocket.bind(
              InternetAddress.anyIPv4, serverContext.port, secCon,
              requestClientCertificate: true)
          .then((SecureServerSocket socket) {
        logger.info(
            'Secondary server started on version : ${AtSecondaryConfig.secondaryServerVersion}');
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
    ServerSocket.bind(InternetAddress.anyIPv4, serverContext.port)
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
    logger.finer('inside _executeVerbCallBack: ${command}');
    try {
      command = SecondaryUtil.convertCommand(command);
      await executor.execute(command, connection, verbManager);
    } on Exception catch (e) {
      logger.severe(e.toString());
      GlobalExceptionHandler.getInstance().handle(e, atConnection: connection);
    } on Error catch (e) {
      logger.severe(e.toString());
      GlobalExceptionHandler.getInstance()
          .handle(InternalServerError(e.toString()), atConnection: connection);
    }
  }

  void _streamCallBack(List<int> data, InboundConnection sender) {
    print('inside stream call back');
    var streamId = sender.getMetaData().streamId;
    print('stream id:${streamId}');
    if (streamId != null) {
      StreamManager.receiverSocketMap[streamId].getSocket().add(data);
    }
  }

  /// Removes all the active connections and stops the secondary server
  /// Throws [AtServerException] if exception occurs in stop the server.
  @override
  void stop() async {
    pause();
    try {
      var result = inboundConnectionFactory.removeAllConnections();
      if (result) {
        //close server socket
        _serverSocket.close();
        await AtCommitLogManagerImpl.getInstance().close();
        await AtAccessLogManagerImpl.getInstance().close();
        await SecondaryPersistenceStoreFactory.getInstance().close();
        atRefreshJob.close();
        commitLogCompactionJobInstance.close();
        accessLogCompactionJobInstance.close();
        _isRunning = false;
      }
    } on Exception catch (e) {
      throw AtServerException(
          'Unable to stop secondary server :${e.toString()}');
    }
  }

  /// Gets the inbound connection metrics and outbound connection metrics.
  /// @return: Returns [ConnectionMetrics]
  @override
  ConnectionMetrics getMetrics() {
    return ConnectionMetricsImpl();
  }

  /// Initializes [AtCommitLog], [AtAccessLog] and [HivePersistenceManager] instances.
  void _initializeHiveInstances() async {
    // Initialize commit log
    var atCommitLog = await AtCommitLogManagerImpl.getInstance().getCommitLog(
        serverContext.currentAtSign,
        commitLogPath: commitLogPath);
    LastCommitIDMetricImpl.getInstance().atCommitLog = atCommitLog;

    // Initialize access log
    var atAccessLog = await AtAccessLogManagerImpl.getInstance().getAccessLog(
        serverContext.currentAtSign,
        accessLogPath: accessLogPath);
    _accessLog = atAccessLog;

    // Initialize notification storage
    var notificationInstance = AtNotificationKeystore.getInstance();
    await notificationInstance.init(
        notificationStoragePath,
        'notifications_' +
            AtUtils.getShaForAtSign(serverContext.currentAtSign));
    // Loads the notifications into Map.
    NotificationUtil.loadNotificationMap();

    // Initialize Secondary Storage
    var secondaryPersistenceStore =
        SecondaryPersistenceStoreFactory.getInstance()
            .getSecondaryPersistenceStore(serverContext.currentAtSign);
    var manager = secondaryPersistenceStore.getHivePersistenceManager();
    await manager.init(serverContext.currentAtSign, storagePath);
    await manager.openVault(serverContext.currentAtSign);
    manager.scheduleKeyExpireTask(expiringRunFreqMins);

    var atData = AtData();
    atData.data = serverContext.sharedSecret;
    var keyStoreManager = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(serverContext.currentAtSign)
        .getSecondaryKeyStoreManager();
    var hiveKeyStore = SecondaryPersistenceStoreFactory.getInstance()
        .getSecondaryPersistenceStore(serverContext.currentAtSign)
        .getSecondaryKeyStore();
    hiveKeyStore.commitLog = atCommitLog;
    _commitLog = atCommitLog;
    keyStoreManager.keyStore = hiveKeyStore;
    serverContext.isKeyStoreInitialized =
        true; //TODO check hive for sample data
    var keyStore = keyStoreManager.getKeyStore();
    var cramData = await keyStore.get(AT_CRAM_SECRET_DELETED);
    var isCramDeleted = cramData?.data;
    if (isCramDeleted == null) {
      await keyStore.put(AT_CRAM_SECRET, atData);
    }
    var signingData = await keyStore.get(AT_SIGNING_KEYPAIR_GENERATED);
    if (signingData == null) {
      var rsaKeypair = RSAKeypair.fromRandom();
      await keyStore.put('$AT_SIGNING_PUBLIC_KEY$currentAtSign',
          AtData()..data = rsaKeypair.publicKey.toString());
      await keyStore.put('$currentAtSign:$AT_SIGNING_PRIVATE_KEY$currentAtSign',
          AtData()..data = rsaKeypair.privateKey.toString());
      await keyStore.put(AT_SIGNING_KEYPAIR_GENERATED, AtData()..data = 'true');
      logger.info('signing keypair generated');
    }
    var signingPrivateKey = await keyStore
        .get('$currentAtSign:$AT_SIGNING_PRIVATE_KEY$currentAtSign');
    signingKey = signingPrivateKey?.data;
    keyStore.deleteExpiredKeys();
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
