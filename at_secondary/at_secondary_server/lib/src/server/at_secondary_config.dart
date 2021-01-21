import 'dart:io';
import 'package:at_secondary/src/conf/config_util.dart';

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
  static String _notificationStoragePath = 'storage/notificationLog';
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
  static int _maxNotificationEntries = 5;
  static bool _autoNotify = true;

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
      ConfigUtil.getPubspecConfig()['version'];

  static final Map<String, String> _envVars = Platform.environment;

  static String get secondaryServerVersion => _secondaryServerVersion;

  static bool get useSSL {
    var result = _getBoolEnvVar('useSSL');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['security'] != null &&
        ConfigUtil.getYaml()['security']['useSSL'] != null) {
      return _useSSL = ConfigUtil.getYaml()['security']['useSSL'];
    }
    return _useSSL;
  }

  static bool get clientCertificateRequired {
    var result = _getBoolEnvVar('clientCertificateRequired');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['security'] != null &&
        ConfigUtil.getYaml()['security']['clientCertificateRequired'] != null) {
      return _clientCertificateRequired =
          ConfigUtil.getYaml()['security']['clientCertificateRequired'];
    }
    return _clientCertificateRequired;
  }

  static int get runRefreshJobHour {
    var result = _getIntEnvVar('runRefreshJobHour');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['refreshJob'] != null &&
        ConfigUtil.getYaml()['refreshJob']['runJobHour'] != null) {
      return _runRefreshJobHour =
          ConfigUtil.getYaml()['refreshJob']['runJobHour'];
    }
    return _runRefreshJobHour;
  }

  static int get maxNotificationEntries {
    var result = _getIntEnvVar('maxNotificationEntries');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['notification'] != null &&
        ConfigUtil.getYaml()['notification']['max_entries'] != null) {
      return _maxNotificationEntries =
          ConfigUtil.getYaml()['notification']['max_entries'];
    }
    return _maxNotificationEntries;
  }

  static int get accessLogSizeInKB {
    var result = _getIntEnvVar('accessLogSizeInKB');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['access_log_compaction'] != null &&
        ConfigUtil.getYaml()['access_log_compaction']['sizeInKB'] != null) {
      return _accessLogSizeInKB =
          ConfigUtil.getYaml()['access_log_compaction']['sizeInKB'];
    }
    return _accessLogSizeInKB;
  }

  static int get accessLogExpiryInDays {
    var result = _getIntEnvVar('accessLogExpiryInDays');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['access_log_compaction'] != null &&
        ConfigUtil.getYaml()['access_log_compaction']['expiryInDays'] != null) {
      return _accessLogExpiryInDays =
          ConfigUtil.getYaml()['access_log_compaction']['expiryInDays'];
    }
    return _accessLogExpiryInDays;
  }

  static int get accessLogCompactionPercentage {
    var result = _getIntEnvVar('accessLogCompactionPercentage');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['access_log_compaction'] != null &&
        ConfigUtil.getYaml()['access_log_compaction']['compactionPercentage'] !=
            null) {
      return _accessLogCompactionPercentage =
          ConfigUtil.getYaml()['access_log_compaction']['compactionPercentage'];
    }
    return _accessLogCompactionPercentage;
  }

  static int get accessLogCompactionFrequencyMins {
    var result = _getIntEnvVar('accessLogCompactionFrequencyMins');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['access_log_compaction'] != null &&
        ConfigUtil.getYaml()['access_log_compaction']
                ['compactionFrequencyMins'] !=
            null) {
      return _accessLogCompactionFrequencyMins =
          ConfigUtil.getYaml()['access_log_compaction']
              ['compactionFrequencyMins'];
    }
    return _accessLogCompactionFrequencyMins;
  }

  static int get commitLogSizeInKB {
    var result = _getIntEnvVar('commitLogSizeInKB');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['commit_log_compaction'] != null &&
        ConfigUtil.getYaml()['commit_log_compaction']['sizeInKB'] != null) {
      return _commitLogSizeInKB =
          ConfigUtil.getYaml()['commit_log_compaction']['sizeInKB'];
    }
    return _commitLogSizeInKB;
  }

  static int get commitLogExpiryInDays {
    var result = _getIntEnvVar('commitLogExpiryInDays');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['commit_log_compaction'] != null &&
        ConfigUtil.getYaml()['commit_log_compaction']['expiryInDays'] != null) {
      return _commitLogExpiryInDays =
          ConfigUtil.getYaml()['commit_log_compaction']['expiryInDays'];
    }
    return _commitLogExpiryInDays;
  }

  static int get commitLogCompactionPercentage {
    var result = _getIntEnvVar('commitLogCompactionPercentage');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['commit_log_compaction'] != null &&
        ConfigUtil.getYaml()['commit_log_compaction']['compactionPercentage'] !=
            null) {
      return _commitLogCompactionPercentage =
          ConfigUtil.getYaml()['commit_log_compaction']['compactionPercentage'];
    }
    return _commitLogCompactionPercentage;
  }

  static int get commitLogCompactionFrequencyMins {
    var result = _getIntEnvVar('commitLogCompactionFrequencyMins');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['commit_log_compaction'] != null &&
        ConfigUtil.getYaml()['commit_log_compaction']
                ['compactionFrequencyMins'] !=
            null) {
      return _commitLogCompactionFrequencyMins =
          ConfigUtil.getYaml()['commit_log_compaction']
              ['compactionFrequencyMins'];
    }
    return _commitLogCompactionFrequencyMins;
  }

  static int get expiringRunFreqMins {
    var result = _getIntEnvVar('expiringRunFreqMins');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['hive'] != null &&
        ConfigUtil.getYaml()['hive']['expiringRunFrequencyMins'] != null) {
      return _expiringRunFreqMins =
          ConfigUtil.getYaml()['hive']['expiringRunFrequencyMins'];
    }
    return _expiringRunFreqMins;
  }

  static String get notificationStoragePath {
    if (_envVars.containsKey('notificationStoragePath')) {
      return _envVars['notificationStoragePath'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['hive'] != null &&
        ConfigUtil.getYaml()['hive']['notificationStoragePath'] != null) {
      return _notificationStoragePath =
          ConfigUtil.getYaml()['hive']['notificationStoragePath'];
    }
    return _notificationStoragePath;
  }

  static String get accessLogPath {
    if (_envVars.containsKey('accessLogPath')) {
      return _envVars['accessLogPath'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['hive'] != null &&
        ConfigUtil.getYaml()['hive']['accessLogPath'] != null) {
      return _accessLogPath = ConfigUtil.getYaml()['hive']['accessLogPath'];
    }
    return _accessLogPath;
  }

  static String get commitLogPath {
    if (_envVars.containsKey('commitLogPath')) {
      return _envVars['commitLogPath'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['hive'] != null &&
        ConfigUtil.getYaml()['hive']['commitLogPath'] != null) {
      return _commitLogPath = ConfigUtil.getYaml()['hive']['commitLogPath'];
    }
    return _commitLogPath;
  }

  static String get storagePath {
    if (_envVars.containsKey('secondaryStoragePath')) {
      return _envVars['secondaryStoragePath'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['hive'] != null &&
        ConfigUtil.getYaml()['hive']['storagePath'] != null) {
      return _storagePath = ConfigUtil.getYaml()['hive']['storagePath'];
    }
    return _storagePath;
  }

  static int get outbound_idletime_millis {
    var result = _getIntEnvVar('outbound_idletime_millis');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['connection'] != null &&
        ConfigUtil.getYaml()['connection']['outbound_idle_time_millis'] !=
            null) {
      return _outbound_idletime_millis =
          ConfigUtil.getYaml()['connection']['outbound_idle_time_millis'];
    }
    return _outbound_idletime_millis;
  }

  static int get inbound_idletime_millis {
    var result = _getIntEnvVar('inbound_idletime_millis');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['connection'] != null &&
        ConfigUtil.getYaml()['connection']['inbound_idle_time_millis'] !=
            null) {
      return _inbound_idletime_millis =
          ConfigUtil.getYaml()['connection']['inbound_idle_time_millis'];
    }
    return _inbound_idletime_millis;
  }

  static int get outbound_max_limit {
    var result = _getIntEnvVar('outbound_max_limit');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['connection'] != null &&
        ConfigUtil.getYaml()['connection']['outbound_max_limit'] != null) {
      return _outbound_max_limit =
          ConfigUtil.getYaml()['connection']['outbound_max_limit'];
    }
    return _outbound_max_limit;
  }

  static int get inbound_max_limit {
    var result = _getIntEnvVar('inbound_max_limit');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['connection'] != null &&
        ConfigUtil.getYaml()['connection']['inbound_max_limit'] != null) {
      return _inbound_max_limit =
          ConfigUtil.getYaml()['connection']['inbound_max_limit'];
    }
    return _inbound_max_limit;
  }

  static int get lookup_depth_of_resolution {
    var result = _getIntEnvVar('lookup_depth_of_resolution');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['lookup'] != null &&
        ConfigUtil.getYaml()['lookup']['depth_of_resolution'] != null) {
      return _lookup_depth_of_resolution =
          ConfigUtil.getYaml()['lookup']['depth_of_resolution'];
    }
    return _lookup_depth_of_resolution;
  }

  static int get stats_top_visits {
    var result = _getIntEnvVar('statsTopVisits');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['stats'] != null &&
        ConfigUtil.getYaml()['stats']['top_visits'] != null) {
      return _stats_top_visits = ConfigUtil.getYaml()['stats']['top_visits'];
    }
    return _stats_top_visits;
  }

  static int get stats_top_keys {
    var result = _getIntEnvVar('statsTopKeys');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['stats'] != null &&
        ConfigUtil.getYaml()['stats']['top_keys'] != null) {
      return _stats_top_keys = ConfigUtil.getYaml()['stats']['top_keys'];
    }
    return _stats_top_keys;
  }

  static bool get autoNotify {
    var result = _getBoolEnvVar('autoNotify');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['notification'] != null &&
        ConfigUtil.getYaml()['notification']['autoNotify'] != null) {
      return _autoNotify = ConfigUtil.getYaml()['notification']['autoNotify'];
    }
    return _autoNotify;
  }

  static String get trustedCertificateLocation {
    if (_envVars.containsKey('securityTrustedCertificateLocation')) {
      return _envVars['securityTrustedCertificateLocation'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['security'] != null &&
        ConfigUtil.getYaml()['security']['trustedCertificateLocation'] !=
            null) {
      return ConfigUtil.getYaml()['security']['trustedCertificateLocation'];
    }
    return _trustedCertificateLocation;
  }

  static String get privateKeyLocation {
    if (_envVars.containsKey('securityPrivateKeyLocation')) {
      return _envVars['securityPrivateKeyLocation'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['security'] != null &&
        ConfigUtil.getYaml()['security']['privateKeyLocation'] != null) {
      return ConfigUtil.getYaml()['security']['privateKeyLocation'];
    }
    return _privateKeyLocation;
  }

  static String get certificateChainLocation {
    if (_envVars.containsKey('securityCertificateChainLocation')) {
      return _envVars['securityCertificateChainLocation'];
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['security'] != null &&
        ConfigUtil.getYaml()['security']['certificateChainLocation'] != null) {
      return ConfigUtil.getYaml()['security']['certificateChainLocation'];
    }
    return _certificateChainLocation;
  }

  static bool get traceLog {
    var result = _getBoolEnvVar('traceLog');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml()['log'] != null &&
        ConfigUtil.getYaml()['log']['trace'] != null) {
      return ConfigUtil.getYaml()['log']['trace'];
    }
    return _traceLog;
  }

  static bool get debugLog {
    var result = _getBoolEnvVar('debugLog');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['log'] != null &&
        ConfigUtil.getYaml()['log']['debug'] != null) {
      return ConfigUtil.getYaml()['log']['debug'];
    }
    return _debugLog;
  }

  static int get rootServerPort {
    var result = _getIntEnvVar('rootServerPort');
    if (result != null) {
      return result;
    }
    if (ConfigUtil.getYaml() != null &&
        ConfigUtil.getYaml()['root_server'] != null &&
        ConfigUtil.getYaml()['root_server']['port'] != null) {
      return ConfigUtil.getYaml()['root_server']['port'];
    }

    return _rootServerPort;
  }

  static String get rootServerUrl {
    if (_envVars.containsKey('rootServerUrl')) {
      return _envVars['rootServerUrl'];
    }
    if (ConfigUtil.getYaml()['root_server'] != null &&
        ConfigUtil.getYaml()['root_server']['url'] != null) {
      return ConfigUtil.getYaml()['root_server']['url'];
    }
    return _rootServerUrl;
  }

  static bool get isForceRestart {
    var result = _getBoolEnvVar('forceRestart');
    if (result != null) {
      return _getBoolEnvVar('forceRestart');
    }
    if (ConfigUtil.getYaml()['certificate_expiry'] != null &&
        ConfigUtil.getYaml()['certificate_expiry']['force_restart'] != null) {
      return ConfigUtil.getYaml()['certificate_expiry']['force_restart'];
    }
    return _isForceRestart;
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
