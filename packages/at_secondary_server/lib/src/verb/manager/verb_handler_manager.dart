import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/info_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/noop_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_all_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_fetch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_remove_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_status_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/pol_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/stats_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/stream_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';

/// The default implementation of [VerbHandlerManager].
class DefaultVerbHandlerManager implements VerbHandlerManager {
  late List<VerbHandler> _verbHandlers;

  final AtKeyValueStore<String, AtData, AtMetaData?> keyValueStore;
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;
  final NotificationManager notificationManager;
  final StatsNotificationService statsNotificationService;
  final EnrollmentManager enrollmentManager;
  final AtCommitLog? _commitLogOverride;
  final AtAccessLog? _accessLogOverride;
  AtCommitLog get commitLog =>
      _commitLogOverride ?? AtSecondaryServerImpl.getInstance().commitLog;
  AtAccessLog get accessLog =>
      _accessLogOverride ?? AtSecondaryServerImpl.getInstance().accessLog;
  late final Atsign atSign;

  DefaultVerbHandlerManager(
    this.keyValueStore,
    this.outboundClientManager,
    this.cacheManager,
    this.statsNotificationService,
    this.notificationManager,
    this.enrollmentManager,
    String atSign, {
    AtCommitLog? commitLog,
    AtAccessLog? accessLog,
  })  : _commitLogOverride = commitLog,
        _accessLogOverride = accessLog {
    this.atSign = atSign.toAtsign();
    _loadVerbHandlers();
  }

  void close() {}

  ///Accepts the command in UTF-8 format and returns the appropriate verbHandler.
  ///@param - utf8EncodedCommand: command in UTF-8 format.
  ///@return - VerbHandler: returns the appropriate verb handler.
  @override
  VerbHandler? getVerbHandler(String utf8EncodedCommand) {
    for (var handler in _verbHandlers) {
      if (handler.accept(utf8EncodedCommand)) {
        return handler;
      }
    }
    return null;
  }

  List<VerbHandler> _loadVerbHandlers() {
    _verbHandlers = [];
    _verbHandlers.add(FromVerbHandler(keyValueStore,
        commitLog: _commitLogOverride, accessLog: _accessLogOverride));
    _verbHandlers
        .add(CramVerbHandler(keyValueStore, accessLog: _accessLogOverride));
    _verbHandlers.add(PkamVerbHandler(keyValueStore));
    _verbHandlers.add(UpdateVerbHandler(
      keyValueStore,
      statsNotificationService,
      notificationManager,
      atSign,
    ));
    _verbHandlers.add(UpdateMetaVerbHandler(
      keyValueStore,
      statsNotificationService,
      notificationManager,
      atSign,
    ));
    _verbHandlers.add(LocalLookupVerbHandler(keyValueStore, enrollmentManager));
    _verbHandlers.add(ProxyLookupVerbHandler(
      keyValueStore,
      outboundClientManager,
      cacheManager,
      accessLog: _accessLogOverride,
    ));
    _verbHandlers.add(LookupVerbHandler(
      keyValueStore,
      outboundClientManager,
      cacheManager,
      enrollmentManager,
      accessLog: _accessLogOverride,
    ));
    _verbHandlers.add(ScanVerbHandler(
      keyValueStore,
      outboundClientManager,
      cacheManager,
    ));
    _verbHandlers.add(PolVerbHandler(
      keyValueStore,
      outboundClientManager,
      cacheManager,
      accessLog: _accessLogOverride,
    ));
    _verbHandlers.add(DeleteVerbHandler(
      keyValueStore,
      statsNotificationService,
      notificationManager,
    ));
    _verbHandlers.add(StatsVerbHandler(keyValueStore));
    _verbHandlers
        .add(ConfigVerbHandler(keyValueStore, commitLog: _commitLogOverride));
    _verbHandlers.add(MonitorVerbHandler(keyValueStore, notificationManager));
    _verbHandlers.add(StreamVerbHandler(keyValueStore, notificationManager));
    _verbHandlers.add(NotifyVerbHandler(keyValueStore, notificationManager));
    _verbHandlers.add(NotifyListVerbHandler(
      keyValueStore,
      notificationManager,
    ));
    _verbHandlers.add(BatchVerbHandler(keyValueStore, this));
    _verbHandlers
        .add(NotifyStatusVerbHandler(keyValueStore, notificationManager));
    _verbHandlers.add(NotifyAllVerbHandler(keyValueStore, notificationManager));
    _verbHandlers.add(SyncProgressiveVerbHandler(keyValueStore,
        commitLog: _commitLogOverride));
    _verbHandlers.add(InfoVerbHandler(keyValueStore));
    _verbHandlers.add(NoOpVerbHandler(keyValueStore));
    _verbHandlers
        .add(NotifyRemoveVerbHandler(keyValueStore, notificationManager));
    _verbHandlers
        .add(NotifyFetchVerbHandler(keyValueStore, notificationManager));
    _verbHandlers.add(EnrollVerbHandler(
        keyValueStore, enrollmentManager, notificationManager));
    _verbHandlers.add(OtpVerbHandler(keyValueStore));
    _verbHandlers
        .add(KeysVerbHandler(keyValueStore, enrollmentManager, atSign));
    return _verbHandlers;
  }
}
