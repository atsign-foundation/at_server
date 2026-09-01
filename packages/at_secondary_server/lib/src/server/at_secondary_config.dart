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

  // Cross-server 'to:' verb. Inbound understanding of 'to:@x' is always on
  // (unauthenticated, serves only data that is already publicly readable via
  // lookup) — see ToVerbHandler. Outbound emission (send 'to:@target' as the
  // first verb on outbound peer connections, which also fetches the peer's
  // public key so no separate lookup is needed) is gated by this flag,
  // default OFF until every atServer understands 'to:'. OutboundClient falls
  // back to the legacy lookup when a peer rejects 'to:'.
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

  // Persistence backend selection. 'hive' (default) keeps the historical
  // Hive stores. 'sqlite' opens one atsign.db per atSign under
  // <storageRoot>/sqlite. A mismatch between this and the on-disk backend
  // marker triggers a migrate-verify-flip at startup (abort on failure).
  static const String _persistenceBackend = 'hive';
  // The common storage root for the backend marker (.persistence_backend) and,
  // for the 'sqlite'/'dual' backends, the SQLite data (<storageRoot>/sqlite).
  // INDEPENDENT of the Hive path constants above (_storagePath / _commitLogPath
  // / ...): with the default 'hive' backend this only locates the marker file —
  // the Hive stores live at those paths, NOT under here. A relative path, so in
  // the secondary container (WORKDIR /atsign) it resolves to /atsign/storage,
  // the mounted persistent volume. Kept equal to the Hive paths' parent by
  // convention so all state lands on that one volume.
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

  // The time interval(in seconds) to notify latest commitID to monitor connections
  // To disable to the feature, set to -1.
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

  //log level configuration. Value should match the name of one of dart logging package's Level.LEVELS
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
  // <@atsign> is a placeholder. To be replaced with actual atsign during runtime
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

  // TODO: Medium priority: Most (all?) getters in this class return a default value but the signatures currently
  //  allow for nulls. Should fix this as has been done for logLevel
  // TODO: Low priority: Lots of very similar boilerplate code here. Not necessarily bad in this particular case, but
  //  could be terser as per the logLevel getter
  static String get logLevel {
    return _getStringEnvVar('logLevel') ??
        getStringValueFromYaml(['log', 'level']) ??
        _defaultLogLevel;
  }

  /// Used to be called "useSSL" and check env and config for "useSSL"
  /// Now we are checking env and config for "useTLS", and for backwards
  /// compatibility reasons we will fallback check env and config for "useSSL"
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

  /// Whether to require a client certificate when another atServer
  /// connects to us. This should NEVER be set to false except in
  /// very specific circumstances, such as a self-contained ephemeral
  /// environment, or for testing purposes.
  ///
  /// This flag also controls whether we present a client certificate
  /// when connecting to another atServer
  ///
  /// - To override from env: `clientCertificateRequired=false`
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

  /// Gates outbound emission of the cross-server `to:` verb as the first verb
  /// on outbound peer connections. Default false (outbound connections use the
  /// legacy `lookup:`/bare-`from:` path, byte for byte). When on, a peer that
  /// rejects `to:` triggers a fallback to the legacy lookup, so enabling is
  /// safe against atServers that do not understand the verb. Override with env
  /// `toVerbOutboundEnabled=true` or yaml `protocol.toVerbOutboundEnabled`.
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
  /// Disable to suppress the periodic prune.
  static bool get enableCommitLogCompactor {
    return _getBoolEnvVar('enableCommitLogCompactor') ??
        _enableCommitLogCompactor;
  }

  /// Whether the access-log compactor cron should be scheduled. No
  /// effect when [AtPersistenceConfig.enableAccessLog] is `false`.
  static bool get enableAccessLogCompactor {
    return _getBoolEnvVar('enableAccessLogCompactor') ??
        _enableAccessLogCompactor;
  }

  /// Whether the notification-keystore compactor cron should be
  /// scheduled. No effect when
  /// [AtPersistenceConfig.enableNotificationKeystore] is `false`.
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

  /// The active persistence backend: `'hive'` (default) or `'sqlite'`.
  /// Override with env `persistenceBackend` or yaml
  /// `persistence.backend`.
  static String get persistenceBackend {
    final result = _getStringEnvVar('persistenceBackend');
    if (result != null) return result;
    try {
      return getConfigFromYaml(['persistence', 'backend']);
    } on ElementNotFoundException {
      return _persistenceBackend;
    }
  }

  /// The common storage root for the backend marker and (for the
  /// `'sqlite'`/`'dual'` backends) the SQLite data. INDEPENDENT of the Hive
  /// paths — with the default `'hive'` backend this only locates the marker
  /// file; the Hive stores live at [storagePath] / [commitLogPath] / etc.,
  /// not under here. Relative to the container working dir in production
  /// (`/atsign` → `/atsign/storage`, the mounted volume). Override with env
  /// `storageRoot` or yaml `persistence.storageRoot`.
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
  /// enrollment that replaced it FIRST AUTHENTICATES.
  ///
  /// A retrofit replaces the credential its connection authenticated as. The
  /// predecessor is capped rather than removed, so sibling clones of the same
  /// keyfile can still upgrade until the cap elapses — and the clock starts
  /// when the successor proves it can authenticate, not when the server
  /// stores it, because storing it proves only that the server wrote a
  /// record while the private half lives client-side.
  ///
  /// The cap written is `min(this, what the predecessor's own key-expiry
  /// posture leaves it)`, and NOT folded against a previously written cap:
  /// re-arming has to be able to push a deadline OUT, or the first sibling's
  /// upgrade fixes a date every laggard is then stranded behind. It re-arms
  /// once per successor, so the predecessor retires one grace period after
  /// the LAST clone upgrades. A laggard stranded past the window recovers via
  /// an ordinary OTP enrollment.
  ///
  /// The default (30 days) is deliberately generous. Two cases decline to cap
  /// at all — a predecessor that is not approved, and a fully-privileged one
  /// whose successor would be gone before the deadline with no other
  /// fully-privileged enrollment surviving it. See
  /// [EnrollmentManager.armRetrofitCapOnFirstAuth].
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

  // implementation for config:set. This method returns a data stream which subscribers listen to for updates
  static Stream<dynamic>? subscribe(ModifiableConfigs configName) {
    if (!_streamListeners.containsKey(configName)) {
      _streamListeners[configName] = ModifiableConfigurationEntry()
        ..streamController = StreamController<dynamic>.broadcast()
        ..defaultValue = AtSecondaryConfig.getDefaultValue(configName);
    }
    return _streamListeners[configName]!.streamController.stream;
  }

  // implementation for config:set. Broadcasts new config value to all the listeners/subscribers
  static void broadcastConfigChange(
      ModifiableConfigs configName, var newConfigValue,
      {bool isReset = false}) {
    // if an entry for the config does not exist new entry is created
    if (!_streamListeners.containsKey(configName)) {
      _streamListeners[configName] = ModifiableConfigurationEntry()
        ..streamController = StreamController<dynamic>.broadcast()
        ..defaultValue = AtSecondaryConfig.getDefaultValue(configName);
    }
    // in case of reset, the default value of that config is broadcast
    if (isReset) {
      _streamListeners[configName]
          ?.streamController
          .add(_streamListeners[configName]!.defaultValue);
      _streamListeners[configName]?.currentValue =
          _streamListeners[configName]!.defaultValue;
      // this else case broadcast new config value
    } else {
      _streamListeners[configName]?.streamController.add(newConfigValue!);
      _streamListeners[configName]?.currentValue = newConfigValue;
    }
  }

  // implementation for config:Set. Returns current value of modifiable configs
  static dynamic getLatestConfigValue(ModifiableConfigs configName) {
    if (_streamListeners.containsKey(configName)) {
      return _streamListeners[configName]?.currentValue ??
          _streamListeners[configName]?.defaultValue;
    }
    return null;
  }

  // implementation for config:set
  // switch case that returns default value of modifiable configs
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
    // If value not found throw exception
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
    // If value not found throw exception
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
