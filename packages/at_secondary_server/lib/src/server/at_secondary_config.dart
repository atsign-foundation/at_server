import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/conf/config_util.dart';
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

class AtSecondaryConfig {
  // Config
  @visibleForTesting
  static YamlMap? configYamlMap = ConfigUtil.getYaml();
  static final Map<ModifiableConfigs, ModifiableConfigurationEntry>
      _streamListeners = {};

  //Certs
  static const bool _useTLS = true;
  static const bool _clientCertificateRequired = true;

  // Gates outbound emission of the cross-server 'to:' verb.
  static const bool _toVerbOutboundEnabled = false;

  //Certificate Paths
  static const String _fullchainLocation = 'certs/fullchain.pem';
  static const String _privkeyLocation = 'certs/privkey.pem';

  static const String _fullchainLocationMtls = 'certs/mtls/fullchain.pem';
  static const String _privkeyLocationMtls = 'certs/mtls/privkey.pem';

  static const String _trustedCertificateLocation = '/etc/cacert/cacert.pem';

  //Secondary Storage
  static const String _storagePath = 'storage/hive';
  static const String _commitLogPath = 'storage/commitLog';
  static const String _accessLogPath = 'storage/accessLog';
  static const String _notificationStoragePath = 'storage/notificationLog.v1';
  static const int _expiringRunFreqMins = 10;

  // Persistence backend: 'hive', 'sqlite' or 'dual'.
  static const String _persistenceBackend = 'hive';
  // Storage root for the backend marker and the SQLite data.
  static const String _storageRoot = 'storage';

  //Commit Log
  static const int _commitLogCompactionFrequencyMins = 18;
  static const int _commitLogCompactionPercentage = 20;
  static const int _commitLogSizeInKB = 2;
  static const bool _enableCommitLogCompactor = true;

  //Access Log
  static const int _accessLogCompactionFrequencyMins = 15;
  static const int _accessLogCompactionPercentage = 30;
  static const int _accessLogSizeInKB = 2;
  static const bool _enableAccessLogCompactor = true;

  //Notification
  static const bool _autoNotify = true;

  // Whether this server is running as a test fixture.
  static const bool _testingMode = false;

  // Interval in seconds for notifying the latest commitID; -1 disables.
  static const int _statsNotificationJobTimeInterval = 15;

  // defines the time after which a notification expires in units of minutes
  static const int _notificationExpiryInMins = 15;

  static const int _notificationKeyStoreCompactionFrequencyMins = 5;
  static const int _notificationKeyStoreCompactionPercentage = 30;
  static const int _notificationKeyStoreSizeInKB = -1;
  static const bool _enableNotificationCompactor = true;

  //Refresh Job
  static const int _runRefreshJobHour = 3;

  //Connection
  static const int _inboundMaxLimit = 200;
  static const int _outboundMaxLimit = 200;
  static const int _unauthenticatedInboundIdleTimeMillis =
      10 * 60 * 1000; // 10 minutes
  static const int _unauthenticatedOutboundIdleTimeMillis =
      _unauthenticatedInboundIdleTimeMillis - 1000;
  static const int _authenticatedInboundIdleTimeMillis =
      10 * 60 * 1000; // 10 minutes
  static const int _authenticatedOutboundIdleTimeMillis =
      _authenticatedInboundIdleTimeMillis - 1000;

  //Lookup
  static const int _lookupDepthOfResolution = 3;

  //Stats
  static const int _statsTopKeys = 5;
  static const int _statsTopVisits = 5;

  // Must match the name of one of the logging package's Level.LEVELS.
  static const String _defaultLogLevel = 'INFO';

  //root server configurations
  static const String _rootServerUrl = 'root.atsign.org';
  static const int _rootServerPort = 64;

  //force restart
  static const bool _isForceRestart = false;

  //Sync Configurations
  static const int _syncBufferSize = 5242880;
  static const int _syncPageLimit = 100;

  // Malformed Keys
  static final List<String> _malformedKeys = [];
  static const bool _shouldRemoveMalformedKeys = true;

  // Protected Keys
  // <@atsign> is a placeholder, replaced with the atSign at runtime.
  static final Set<String> _protectedKeys = {
    'signing_publickey<@atsign>',
    'signing_privatekey<@atsign>',
    'publickey<@atsign>',
    'at_pkam_publickey'
  };

  //version
  static final String? _secondaryServerVersion =
      (ConfigUtil.getPubspecConfig() != null &&
              ConfigUtil.getPubspecConfig()!['version'] != null)
          ? ConfigUtil.getPubspecConfig()!['version']
          : null;

  static final Map<String, String> _envVars = Platform.environment;

  static String? get secondaryServerVersion => _secondaryServerVersion;

  static String get logLevel {
    return _getStringEnvVar('logLevel') ??
        getStringValueFromYaml(['log', 'level']) ??
        _defaultLogLevel;
  }

  /// Reads `useTLS` from env and config, falling back to the older `useSSL`.
  static bool? get useTLS {
    var result = _getBoolEnvVar('useTLS');
    if (result != null) {
      return result;
    }

    result = _getBoolEnvVar('useSSL');
    if (result != null) {
      return result;
    }

    try {
      return getConfigFromYaml(['security', 'useTLS']);
    } on ElementNotFoundException {
      try {
        return getConfigFromYaml(['security', 'useSSL']);
      } on ElementNotFoundException {
        return _useTLS;
      }
    }
  }

  /// Whether a client certificate is required inbound and presented outbound.
  static bool get clientCertificateRequired {
    var result = _getBoolEnvVar('clientCertificateRequired');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['security', 'clientCertificateRequired']);
    } on ElementNotFoundException {
      return _clientCertificateRequired;
    }
  }

  /// Gates outbound emission of the cross-server `to:` verb.
  static bool get toVerbOutboundEnabled {
    var result = _getBoolEnvVar('toVerbOutboundEnabled');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['protocol', 'toVerbOutboundEnabled']);
    } on ElementNotFoundException {
      return _toVerbOutboundEnabled;
    }
  }

  static int? get runRefreshJobHour {
    var result = _getIntEnvVar('runRefreshJobHour');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['refreshJob', 'runJobHour']);
    } on ElementNotFoundException {
      return _runRefreshJobHour;
    }
  }

  static int? get accessLogSizeInKB {
    var result = _getIntEnvVar('accessLogSizeInKB');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['access_log_compaction', 'sizeInKB']);
    } on ElementNotFoundException {
      return _accessLogSizeInKB;
    }
  }

  static int? get accessLogCompactionPercentage {
    var result = _getIntEnvVar('accessLogCompactionPercentage');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['access_log_compaction', 'compactionPercentage']);
    } on ElementNotFoundException {
      return _accessLogCompactionPercentage;
    }
  }

  static int get accessLogCompactionFrequencyMins {
    return _getIntEnvVar('accessLogCompactionFrequencyMins') ??
        getNullableIntFromYaml(
            ['access_log_compaction', 'compactionFrequencyMins']) ??
        _accessLogCompactionFrequencyMins;
  }

  static int? get commitLogSizeInKB {
    var result = _getIntEnvVar('commitLogSizeInKB');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['commit_log_compaction', 'sizeInKB']);
    } on ElementNotFoundException {
      return _commitLogSizeInKB;
    }
  }

  static int? get commitLogCompactionPercentage {
    var result = _getIntEnvVar('commitLogCompactionPercentage');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['commit_log_compaction', 'compactionPercentage']);
    } on ElementNotFoundException {
      return _commitLogCompactionPercentage;
    }
  }

  static int get commitLogCompactionFrequencyMins {
    return _getIntEnvVar('commitLogCompactionFrequencyMins') ??
        getNullableIntFromYaml(
            ['commit_log_compaction', 'compactionFrequencyMins']) ??
        _commitLogCompactionFrequencyMins;
  }

  static int? get expiringRunFreqMins {
    var result = _getIntEnvVar('expiringRunFreqMins');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['hive', 'expiringRunFrequencyMins']);
    } on ElementNotFoundException {
      return _expiringRunFreqMins;
    }
  }

  static int get notificationKeyStoreCompactionPercentage {
    return _getIntEnvVar('notificationKeyStoreCompactionPercentage') ??
        getNullableIntFromYaml(
            ['notification_keystore_compaction', 'compactionPercentage']) ??
        _notificationKeyStoreCompactionPercentage;
  }

  static int? get notificationKeyStoreSizeInKB {
    var result = _getIntEnvVar('notificationKeyStoreInKB');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['notification_keystore_compaction', 'sizeInKB']);
    } on ElementNotFoundException {
      return _notificationKeyStoreSizeInKB;
    }
  }

  static int get notificationKeyStoreCompactionFrequencyMins {
    return _getIntEnvVar('notificationKeyStoreCompactionFrequencyMins') ??
        getNullableIntFromYaml(
            ['notification_keystore_compaction', 'compactionFrequencyMins']) ??
        _notificationKeyStoreCompactionFrequencyMins;
  }

  /// Whether the commit-log compactor cron should be scheduled.
  static bool get enableCommitLogCompactor {
    return _getBoolEnvVar('enableCommitLogCompactor') ??
        _enableCommitLogCompactor;
  }

  /// Whether the access-log compactor cron should be scheduled.
  static bool get enableAccessLogCompactor {
    return _getBoolEnvVar('enableAccessLogCompactor') ??
        _enableAccessLogCompactor;
  }

  /// Whether the notification-keystore compactor cron should be scheduled.
  static bool get enableNotificationCompactor {
    return _getBoolEnvVar('enableNotificationCompactor') ??
        _enableNotificationCompactor;
  }

  static String get notificationStoragePath {
    if (_envVars['notificationStoragePath'] != null) {
      return _envVars['notificationStoragePath']!;
    }
    try {
      return getConfigFromYaml(['hive', 'notificationStoragePath']);
    } on ElementNotFoundException {
      return _notificationStoragePath;
    }
  }

  static String get accessLogPath {
    if (_envVars['accessLogPath'] != null) {
      return _envVars['accessLogPath']!;
    }
    try {
      return getConfigFromYaml(['hive', 'accessLogPath']);
    } on ElementNotFoundException {
      return _accessLogPath;
    }
  }

  static String get commitLogPath {
    if (_envVars['commitLogPath'] != null) {
      return _envVars['commitLogPath']!;
    }
    try {
      return getConfigFromYaml(['hive', 'commitLogPath']);
    } on ElementNotFoundException {
      return _commitLogPath;
    }
  }

  static String get storagePath {
    if (_envVars['secondaryStoragePath'] != null) {
      return _envVars['secondaryStoragePath']!;
    }
    try {
      return getConfigFromYaml(['hive', 'storagePath']);
    } on ElementNotFoundException {
      return _storagePath;
    }
  }

  /// The active persistence backend, `'hive'` or `'sqlite'`.
  static String get persistenceBackend {
    final result = _getStringEnvVar('persistenceBackend');
    if (result != null) return result;
    try {
      return getConfigFromYaml(['persistence', 'backend']);
    } on ElementNotFoundException {
      return _persistenceBackend;
    }
  }

  /// Storage root for the backend marker and the SQLite data.
  static String get storageRoot {
    final result = _getStringEnvVar('storageRoot');
    if (result != null) return result;
    try {
      return getConfigFromYaml(['persistence', 'storageRoot']);
    } on ElementNotFoundException {
      return _storageRoot;
    }
  }

  // ignore: non_constant_identifier_names
  static int get unauthenticated_outbound_idletime_millis {
    var result = _getIntEnvVar('outbound_idletime_millis');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'outbound_idle_time_millis']);
    } on ElementNotFoundException {
      return _unauthenticatedOutboundIdleTimeMillis;
    }
  }

  // ignore: non_constant_identifier_names
  static int get unauthenticated_inbound_idletime_millis {
    var result = _getIntEnvVar('inbound_idletime_millis');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'inbound_idle_time_millis']);
    } on ElementNotFoundException {
      return _unauthenticatedInboundIdleTimeMillis;
    }
  }

  // ignore: non_constant_identifier_names
  static int get authenticated_inbound_idletime_millis {
    var result = _getIntEnvVar('authenticated_inbound_idletime_millis');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['connection', 'authenticated_inbound_idle_time_millis']);
    } on ElementNotFoundException {
      return _authenticatedInboundIdleTimeMillis;
    }
  }

  // ignore: non_constant_identifier_names
  static int get authenticated_outbound_idletime_millis {
    var result = _getIntEnvVar('authenticated_outbound_idletime_millis');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['connection', 'authenticated_outbound_idle_time_millis']);
    } on ElementNotFoundException {
      return _authenticatedOutboundIdleTimeMillis;
    }
  }

  // ignore: non_constant_identifier_names
  static int get outbound_max_limit {
    var result = _getIntEnvVar('outbound_max_limit');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'outbound_max_limit']);
    } on ElementNotFoundException {
      return _outboundMaxLimit;
    }
  }

  // ignore: non_constant_identifier_names
  static int get inbound_max_limit {
    var result = _getIntEnvVar('inbound_max_limit');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'inbound_max_limit']);
    } on ElementNotFoundException {
      return _inboundMaxLimit;
    }
  }

  // ignore: non_constant_identifier_names
  static int? get lookup_depth_of_resolution {
    var result = _getIntEnvVar('lookup_depth_of_resolution');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['lookup', 'depth_of_resolution']);
    } on ElementNotFoundException {
      return _lookupDepthOfResolution;
    }
  }

  // ignore: non_constant_identifier_names
  static int? get stats_top_visits {
    var result = _getIntEnvVar('statsTopVisits');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['stats', 'top_visits']);
    } on ElementNotFoundException {
      return _statsTopVisits;
    }
  }

  // ignore: non_constant_identifier_names
  static int? get stats_top_keys {
    var result = _getIntEnvVar('statsTopKeys');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['stats', 'top_keys']);
    } on ElementNotFoundException {
      return _statsTopKeys;
    }
  }

  static bool get autoNotify {
    var result = _getBoolEnvVar('autoNotify');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['notification', 'autoNotify']);
    } on ElementNotFoundException {
      return _autoNotify;
    }
  }

  /// Forces [testingMode] to a value for the duration of a test; null asks the
  /// environment and the yaml, as every non-test run does.
  @visibleForTesting
  static bool? testingModeOverride;

  /// Whether this server is running as a test fixture; only a bool `true` or
  /// the string `true` in env or yaml answers true, and anything else,
  /// including an unparseable setting, answers false.
  static bool get testingMode {
    if (testingModeOverride != null) {
      return testingModeOverride!;
    }
    var result = _getBoolEnvVar('testingMode');
    if (result != null) {
      return result;
    }
    final dynamic configured;
    try {
      configured = getConfigFromYaml(['testing', 'testingMode']);
    } on ElementNotFoundException {
      return _testingMode;
    }
    if (configured is bool) {
      return configured;
    }
    return configured is String && configured.trim().toLowerCase() == 'true';
  }

  static String get trustedCertificateLocation {
    if (_envVars.containsKey('securityTrustedCertificateLocation')) {
      return _envVars['securityTrustedCertificateLocation']!;
    }
    try {
      return getConfigFromYaml(['security', 'trustedCertificateLocation']);
    } on ElementNotFoundException {
      return _trustedCertificateLocation;
    }
  }

  static String get privateKeyLocation {
    if (_envVars.containsKey('securityPrivateKeyLocation')) {
      return _envVars['securityPrivateKeyLocation']!;
    }
    try {
      return getConfigFromYaml(['security', 'privateKeyLocation']);
    } on ElementNotFoundException {
      return _privkeyLocation;
    }
  }

  static String get certificateChainLocation {
    if (_envVars.containsKey('securityCertificateChainLocation')) {
      return _envVars['securityCertificateChainLocation']!;
    }
    try {
      return getConfigFromYaml(['security', 'certificateChainLocation']);
    } on ElementNotFoundException {
      return _fullchainLocation;
    }
  }

  static String get privateKeyLocationMtls {
    if (_envVars.containsKey('securityPrivateKeyLocationMtls')) {
      return _envVars['securityPrivateKeyLocationMtls']!;
    }
    try {
      return getConfigFromYaml(['security', 'privateKeyLocationMtls']);
    } on ElementNotFoundException {
      return _privkeyLocationMtls;
    }
  }

  static String get certificateChainLocationMtls {
    if (_envVars.containsKey('securityCertificateChainLocationMtls')) {
      return _envVars['securityCertificateChainLocationMtls']!;
    }
    try {
      return getConfigFromYaml(['security', 'certificateChainLocationMtls']);
    } on ElementNotFoundException {
      return _fullchainLocationMtls;
    }
  }

  static int get rootServerPort {
    var result = _getIntEnvVar('rootServerPort');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['root_server', 'port']);
    } on ElementNotFoundException {
      return _rootServerPort;
    }
  }

  static String get rootServerUrl {
    if (_envVars.containsKey('rootServerUrl')) {
      return _envVars['rootServerUrl']!;
    }
    try {
      return getConfigFromYaml(['root_server', 'url']);
    } on ElementNotFoundException {
      return _rootServerUrl;
    }
  }

  static bool get isForceRestart {
    bool? result = _getBoolEnvVar('forceRestart');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['certificate_expiry', 'force_restart']);
    } on ElementNotFoundException {
      return _isForceRestart;
    }
  }

  static int get statsNotificationJobTimeInterval {
    var result = _getIntEnvVar('statsNotificationJobTimeInterval');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['notification', 'statsNotificationJobTimeInterval']);
    } on ElementNotFoundException {
      return _statsNotificationJobTimeInterval;
    }
  }

  /// The default ttl for notification expiration
  static int get notificationExpiryInMins {
    var result = _getIntEnvVar('notificationExpiryInMins');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['notification', 'expiryInMins']);
    } on ElementNotFoundException {
      return _notificationExpiryInMins;
    }
  }

  static int get syncBufferSize {
    var result = _getIntEnvVar('syncBufferSize');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['sync', 'bufferSize']);
    } on ElementNotFoundException {
      return _syncBufferSize;
    }
  }

  static int get syncPageLimit {
    var result = _getIntEnvVar('syncPageLimit');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['sync', 'pageLimit']);
    } on ElementNotFoundException {
      return _syncPageLimit;
    }
  }

  static List<String> get malformedKeysList {
    var result = _getStringEnvVar('hiveMalformedKeys');
    if (result != null) {
      return result.split(',');
    }
    try {
      return getConfigFromYaml(['hive', 'malformedKeys']).split(',');
    } on ElementNotFoundException {
      return _malformedKeys;
    }
  }

  static bool get shouldRemoveMalformedKeys {
    var result = _getBoolEnvVar('shouldRemoveMalformedKeys');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['hive', 'shouldRemoveMalformedKeys']);
    } on ElementNotFoundException {
      return _shouldRemoveMalformedKeys;
    }
  }

  static Set<String> get protectedKeys {
    try {
      YamlList keys = getConfigFromYaml(['hive', 'protectedKeys']);
      Set<String> protectedKeysFromConfig = {};
      for (var key in keys) {
        protectedKeysFromConfig.add(key);
      }
      protectedKeysFromConfig.addAll(_protectedKeys);
      return protectedKeysFromConfig;
    } on Exception {
      return _protectedKeys;
    }
  }

  static int get enrollmentExpiryInHours {
    return _getIntEnvVar('enrollmentExpiryInHours') ??
        getNullableIntFromYaml(['enrollment', 'expiryInHours']) ??
        48;
  }

  /// How long a superseded enrollment keeps authenticating after the
  /// enrollment that replaced it first authenticates.
  static int get apkamSelfEnrollmentGraceHours {
    return _getIntEnvVar('apkamSelfEnrollmentGraceHours') ??
        getNullableIntFromYaml(
            ['enrollment', 'apkamSelfEnrollmentGraceHours']) ??
        720;
  }

  static final int _enrollmentResponseDelayIntervalInSeconds = 55;

  static int? _maxEnrollRequestsAllowed;

  static set maxEnrollRequestsAllowed(int value) {
    _maxEnrollRequestsAllowed = value;
  }

  static int get maxEnrollRequestsAllowed {
    return _maxEnrollRequestsAllowed ??
        _getIntEnvVar('maxEnrollRequestsAllowed') ??
        getNullableIntFromYaml(['enrollment', 'maxRequestsPerTimeFrame']) ??
        5;
  }

  static final int _timeFrameInHours = 1;
  static int? _timeFrameInMillis;

  static set timeFrameInMillis(int timeWindowInMills) {
    _timeFrameInMillis = timeWindowInMills;
  }

  static int get timeFrameInMillis {
    return _timeFrameInMillis ??
        (_getIntEnvVar('enrollTimeFrameInHours') ??
                getNullableIntFromYaml(['enrollment', 'timeFrameInHours']) ??
                _timeFrameInHours) *
            60 *
            60 *
            1000;
  }

  static int get enrollmentResponseDelayIntervalInSeconds {
    var result = _getIntEnvVar('enrollmentDelayIntervalThreshold');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['enrollment', 'delayIntervalThreshold']);
    } on ElementNotFoundException {
      return _enrollmentResponseDelayIntervalInSeconds;
    }
  }

  // The stream subscribers listen on for config:set updates.
  static Stream<dynamic>? subscribe(ModifiableConfigs configName) {
    if (!_streamListeners.containsKey(configName)) {
      _streamListeners[configName] = ModifiableConfigurationEntry()
        ..streamController = StreamController<dynamic>.broadcast()
        ..defaultValue = AtSecondaryConfig.getDefaultValue(configName);
    }
    return _streamListeners[configName]!.streamController.stream;
  }

  // Broadcasts a new config value to every subscriber, for config:set.
  static void broadcastConfigChange(
      ModifiableConfigs configName, var newConfigValue,
      {bool isReset = false}) {
    if (!_streamListeners.containsKey(configName)) {
      _streamListeners[configName] = ModifiableConfigurationEntry()
        ..streamController = StreamController<dynamic>.broadcast()
        ..defaultValue = AtSecondaryConfig.getDefaultValue(configName);
    }
    if (isReset) {
      _streamListeners[configName]
          ?.streamController
          .add(_streamListeners[configName]!.defaultValue);
      _streamListeners[configName]?.currentValue =
          _streamListeners[configName]!.defaultValue;
    } else {
      _streamListeners[configName]?.streamController.add(newConfigValue!);
      _streamListeners[configName]?.currentValue = newConfigValue;
    }
  }

  // The current value of a modifiable config, for config:set.
  static dynamic getLatestConfigValue(ModifiableConfigs configName) {
    if (_streamListeners.containsKey(configName)) {
      return _streamListeners[configName]?.currentValue ??
          _streamListeners[configName]?.defaultValue;
    }
    return null;
  }

  // The default value of a modifiable config, which config:set resets to.
  static Object getDefaultValue(ModifiableConfigs configName) {
    switch (configName) {
      case ModifiableConfigs.accessLogCompactionFrequencyMins:
        return accessLogCompactionFrequencyMins;
      case ModifiableConfigs.commitLogCompactionFrequencyMins:
        return commitLogCompactionFrequencyMins;
      case ModifiableConfigs.notificationKeyStoreCompactionFrequencyMins:
        return notificationKeyStoreCompactionFrequencyMins;
      case ModifiableConfigs.inboundMaxLimit:
        return inbound_max_limit;
      case ModifiableConfigs.autoNotify:
        return autoNotify;
      case ModifiableConfigs.checkCertificateReload:
        return false;
      case ModifiableConfigs.shouldReloadCertificates:
        return false;
      case ModifiableConfigs.doCacheRefreshNow:
        return false;
      case ModifiableConfigs.maxRequestsPerTimeFrame:
        return maxEnrollRequestsAllowed;
      case ModifiableConfigs.timeFrameInMillis:
        return Duration(hours: _timeFrameInHours).inMilliseconds;
    }
  }

  static int? _getIntEnvVar(String envVar) {
    if (_envVars.containsKey(envVar)) {
      return int.parse(_envVars[envVar]!);
    }
    return null;
  }

  static bool? _getBoolEnvVar(String envVar) {
    if (_envVars.containsKey(envVar)) {
      return (_envVars[envVar]!.toLowerCase() == 'true') ? true : false;
    }
    return null;
  }

  static String? _getStringEnvVar(String envVar) {
    if (_envVars.containsKey(envVar)) {
      return _envVars[envVar];
    }
    return null;
  }

  static int? getNullableIntFromYaml(List<String> args) {
    try {
      return getConfigFromYaml(args);
    } on ElementNotFoundException catch (_) {
      return null;
    }
  }

  static dynamic getConfigFromYaml(List<String> args) {
    var yamlMap = AtSecondaryConfig.configYamlMap;
    // ignore: prefer_typing_uninitialized_variables
    var value;
    if (yamlMap != null) {
      for (int i = 0; i < args.length; i++) {
        if (i == 0) {
          value = yamlMap[args[i]];
        } else {
          if (value != null) {
            value = value[args[i]];
          }
        }
      }
    }
    if (value == Null || value == null) {
      throw ElementNotFoundException(
          'Element ${args.toString()} Not Found in yaml');
    }
    return value;
  }

  static String? getStringValueFromYaml(List<String> keyParts) {
    var yamlMap = AtSecondaryConfig.configYamlMap;
    // ignore: prefer_typing_uninitialized_variables
    var value;
    if (yamlMap != null) {
      for (int i = 0; i < keyParts.length; i++) {
        if (i == 0) {
          value = yamlMap[keyParts[i]];
        } else {
          if (value != null) {
            value = value[keyParts[i]];
          }
        }
      }
    }
    if (value == Null || value == null) {
      return null;
    } else {
      return value.toString();
    }
  }
}

enum ModifiableConfigs {
  inboundMaxLimit,
  commitLogCompactionFrequencyMins,
  accessLogCompactionFrequencyMins,
  notificationKeyStoreCompactionFrequencyMins,
  autoNotify,
  checkCertificateReload,
  shouldReloadCertificates,
  doCacheRefreshNow,
  maxRequestsPerTimeFrame,
  timeFrameInMillis
}

class ModifiableConfigurationEntry {
  late StreamController<dynamic> streamController;
  late dynamic defaultValue;
  dynamic currentValue;
}

class ElementNotFoundException extends AtException {
  ElementNotFoundException(super.message);
}
