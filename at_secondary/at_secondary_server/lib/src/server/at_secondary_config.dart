import 'dart:io';
import 'package:at_secondary/src/conf/config_util.dart';
import 'package:at_commons/at_commons.dart';

class AtSecondaryConfig {
  //Certs
  static bool _useSSL = true;
  static bool _clientCertificateRequired = true;

  //Certificate Paths
  static final String _certificateChainLocation = 'certs/fullchain.pem';
  static final String _privateKeyLocation = 'certs/privkey.pem';
  static final String _trustedCertificateLocation = 'certs/cacert.pem';

  //Secondary Storage
  static String _storagePath = 'storage/hive';
  static String _commitLogPath = 'storage/commitLog';
  static String _accessLogPath = 'storage/accessLog';
  static String _notificationStoragePath = 'storage/notificationLog.v1';
  static int _expiringRunFreqMins = 10;

  //Commit Log
  static int _commitLogCompactionFrequencyMins = 30;
  static int _commitLogCompactionPercentage = 20;
  static int _commitLogExpiryInDays = 15;
  static int _commitLogSizeInKB = 2;

  //Access Log
  static int _accessLogCompactionFrequencyMins = 15;
  static int _accessLogCompactionPercentage = 30;
  static int _accessLogExpiryInDays = 15;
  static int _accessLogSizeInKB = 2;

  //Notification
  static final int _maxNotificationRetries = 5;
  static int _maxNotificationEntries = 5;
  static bool _autoNotify = true;
  static final int _notificationQuarantineDuration = 10;
  static final int _notificationJobFrequency = 5;

  //Refresh Job
  static int _runRefreshJobHour = 3;

  //Connection
  static int _inbound_max_limit = 10;
  static int _outbound_max_limit = 10;
  static int _inbound_idletime_millis = 600000;
  static int _outbound_idletime_millis = 600000;

  //Lookup
  static int _lookup_depth_of_resolution = 3;

  //Stats
  static int _stats_top_keys = 5;
  static int _stats_top_visits = 5;

  //log configurations
  static final bool _debugLog = true;
  static final bool _traceLog = true;

  //root server configurations
  static final String _rootServerUrl = 'root.atsign.org';
  static final int _rootServerPort = 64;

  //force restart
  static final bool _isForceRestart = false;

  //version
  static final String _secondaryServerVersion =
      (ConfigUtil.getPubspecConfig() != null &&
              ConfigUtil.getPubspecConfig()['version'] != null)
          ? ConfigUtil.getPubspecConfig()['version']
          : null;

  static final Map<String, String> _envVars = Platform.environment;

  static String get secondaryServerVersion => _secondaryServerVersion;

  static bool get useSSL {
    var result = _getBoolEnvVar('useSSL');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['security', 'useSSL']);
    } on ElementNotFoundException {
      return _useSSL;
    }
  }

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

  static int get runRefreshJobHour {
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

  static int get maxNotificationEntries {
    var result = _getIntEnvVar('maxNotificationEntries');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['notification', 'max_entries']);
    } on ElementNotFoundException {
      return _maxNotificationEntries;
    }
  }

  static int get accessLogSizeInKB {
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

  static int get accessLogExpiryInDays {
    var result = _getIntEnvVar('accessLogExpiryInDays');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['access_log_compaction', 'expiryInDays']);
    } on ElementNotFoundException {
      return _accessLogExpiryInDays;
    }
  }

  static int get accessLogCompactionPercentage {
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
    var result = _getIntEnvVar('accessLogCompactionFrequencyMins');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['access_log_compaction', 'compactionFrequencyMins']);
    } on ElementNotFoundException {
      return _accessLogCompactionFrequencyMins;
    }
  }

  static int get commitLogSizeInKB {
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

  static int get commitLogExpiryInDays {
    var result = _getIntEnvVar('commitLogExpiryInDays');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['commit_log_compaction', 'expiryInDays']);
    } on ElementNotFoundException {
      return _commitLogExpiryInDays;
    }
  }

  static int get commitLogCompactionPercentage {
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
    var result = _getIntEnvVar('commitLogCompactionFrequencyMins');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(
          ['commit_log_compaction', 'compactionFrequencyMins']);
    } on ElementNotFoundException {
      return _commitLogCompactionFrequencyMins;
    }
  }

  static int get expiringRunFreqMins {
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

  static String get notificationStoragePath {
    if (_envVars.containsKey('notificationStoragePath')) {
      return _envVars['notificationStoragePath'];
    }
    try {
      return getConfigFromYaml(['hive', 'notificationStoragePath']);
    } on ElementNotFoundException {
      return _notificationStoragePath;
    }
  }

  static String get accessLogPath {
    if (_envVars.containsKey('accessLogPath')) {
      return _envVars['accessLogPath'];
    }
    try {
      return getConfigFromYaml(['hive', 'accessLogPath']);
    } on ElementNotFoundException {
      return _accessLogPath;
    }
  }

  static String get commitLogPath {
    if (_envVars.containsKey('commitLogPath')) {
      return _envVars['commitLogPath'];
    }
    try {
      return getConfigFromYaml(['hive', 'commitLogPath']);
    } on ElementNotFoundException {
      return _commitLogPath;
    }
  }

  static String get storagePath {
    if (_envVars.containsKey('secondaryStoragePath')) {
      return _envVars['secondaryStoragePath'];
    }
    try {
      return getConfigFromYaml(['hive', 'storagePath']);
    } on ElementNotFoundException {
      return _storagePath;
    }
  }

  static int get outbound_idletime_millis {
    var result = _getIntEnvVar('outbound_idletime_millis');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'outbound_idle_time_millis']);
    } on ElementNotFoundException {
      return _outbound_idletime_millis;
    }
  }

  static int get inbound_idletime_millis {
    var result = _getIntEnvVar('inbound_idletime_millis');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'inbound_idle_time_millis']);
    } on ElementNotFoundException {
      return _inbound_idletime_millis;
    }
  }

  static int get outbound_max_limit {
    var result = _getIntEnvVar('outbound_max_limit');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'outbound_max_limit']);
    } on ElementNotFoundException {
      return _outbound_max_limit;
    }
  }

  static int get inbound_max_limit {
    var result = _getIntEnvVar('inbound_max_limit');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['connection', 'inbound_max_limit']);
    } on ElementNotFoundException {
      return _inbound_max_limit;
    }
  }

  static int get lookup_depth_of_resolution {
    var result = _getIntEnvVar('lookup_depth_of_resolution');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['lookup', 'depth_of_resolution']);
    } on ElementNotFoundException {
      return _lookup_depth_of_resolution;
    }
  }

  static int get stats_top_visits {
    var result = _getIntEnvVar('statsTopVisits');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['stats', 'top_visits']);
    } on ElementNotFoundException {
      return _stats_top_visits;
    }
  }

  static int get stats_top_keys {
    var result = _getIntEnvVar('statsTopKeys');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['stats', 'top_keys']);
    } on ElementNotFoundException {
      return _stats_top_keys;
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

  static String get trustedCertificateLocation {
    if (_envVars.containsKey('securityTrustedCertificateLocation')) {
      return _envVars['securityTrustedCertificateLocation'];
    }
    try {
      return getConfigFromYaml(['security', 'trustedCertificateLocation']);
    } on ElementNotFoundException {
      return _trustedCertificateLocation;
    }
  }

  static String get privateKeyLocation {
    if (_envVars.containsKey('securityPrivateKeyLocation')) {
      return _envVars['securityPrivateKeyLocation'];
    }
    try {
      return getConfigFromYaml(['security', 'privateKeyLocation']);
    } on ElementNotFoundException {
      return _privateKeyLocation;
    }
  }

  static String get certificateChainLocation {
    if (_envVars.containsKey('securityCertificateChainLocation')) {
      return _envVars['securityCertificateChainLocation'];
    }
    try {
      return getConfigFromYaml(['security', 'certificateChainLocation']);
    } on ElementNotFoundException {
      return _certificateChainLocation;
    }
  }

  static bool get traceLog {
    var result = _getBoolEnvVar('traceLog');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['log', 'trace']);
    } on ElementNotFoundException {
      return _traceLog;
    }
  }

  static bool get debugLog {
    var result = _getBoolEnvVar('debugLog');
    if (result != null) {
      return result;
    }
    try {
      return getConfigFromYaml(['log', 'debug']);
    } on ElementNotFoundException {
      return _debugLog;
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
      return _envVars['rootServerUrl'];
    }
    try {
      return getConfigFromYaml(['root_server', 'url']);
    } on ElementNotFoundException {
      return _rootServerUrl;
    }
  }

  static bool get isForceRestart {
    var result = _getBoolEnvVar('forceRestart');
    if (result != null) {
      return _getBoolEnvVar('forceRestart');
    }
    try {
      return getConfigFromYaml(['certificate_expiry', 'force_restart']);
    } on ElementNotFoundException {
      return _isForceRestart;
    }
  }

  static int get maxNotificationRetries {
    var result = _getIntEnvVar('maxNotificationRetries');
    if (result != null) {
      return _getIntEnvVar('maxNotificationRetries');
    }
    try {
      return getConfigFromYaml(['notification', 'max_retries']);
    } on ElementNotFoundException {
      return _maxNotificationRetries;
    }
  }

  static int get notificationQuarantineDuration {
    var result = _getIntEnvVar('notificationQuarantineDuration');
    if (result != null) {
      return _getIntEnvVar('notificationQuarantineDuration');
    }
    try {
      return getConfigFromYaml(['notification', 'quarantineDuration']);
    } on ElementNotFoundException {
      return _notificationQuarantineDuration;
    }
  }

  static int get notificationJobFrequency {
    var result = _getIntEnvVar('notificationJobFrequency');
    if (result != null) {
      return _getIntEnvVar('notificationJobFrequency');
    }
    try {
      return getConfigFromYaml(['notification', 'jobFrequency']);
    } on ElementNotFoundException {
      return _notificationJobFrequency;
    }
  }

  static int _getIntEnvVar(String envVar) {
    if (_envVars.containsKey(envVar)) {
      return int.parse(_envVars[envVar]);
    }
    return null;
  }

  static bool _getBoolEnvVar(String envVar) {
    if (_envVars.containsKey(envVar)) {
      (_envVars[envVar].toLowerCase() == 'true') ? true : false;
    }
    return null;
  }
}

dynamic getConfigFromYaml(List<String> args) {
  var yamlMap = ConfigUtil.getYaml();
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
  // If value not found throw exception
  if (value == Null || value == null) {
    throw ElementNotFoundException('Element Not Found in yaml');
  }
  return value;
}
