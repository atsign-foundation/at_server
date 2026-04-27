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

  final SecondaryKeyStore keyStore;
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
    this.keyStore,
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
    _verbHandlers.add(FromVerbHandler(keyStore,
        commitLog: _commitLogOverride, accessLog: _accessLogOverride));
    _verbHandlers.add(
        CramVerbHandler(keyStore, accessLog: _accessLogOverride));
    _verbHandlers.add(PkamVerbHandler(keyStore));
    _verbHandlers.add(UpdateVerbHandler(
      keyStore,
      statsNotificationService,
      notificationManager,
      atSign,
    ));
    _verbHandlers.add(UpdateMetaVerbHandler(
      keyStore,
      statsNotificationService,
      notificationManager,
      atSign,
    ));
    _verbHandlers.add(LocalLookupVerbHandler(keyStore, enrollmentManager));
    _verbHandlers.add(ProxyLookupVerbHandler(
      keyStore,
      outboundClientManager,
      cacheManager,
      accessLog: _accessLogOverride,
    ));
    _verbHandlers.add(LookupVerbHandler(
      keyStore,
      outboundClientManager,
      cacheManager,
      enrollmentManager,
      accessLog: _accessLogOverride,
    ));
    _verbHandlers.add(ScanVerbHandler(
      keyStore,
      outboundClientManager,
      cacheManager,
    ));
    _verbHandlers.add(PolVerbHandler(
      keyStore,
      outboundClientManager,
      cacheManager,
      accessLog: _accessLogOverride,
    ));
    _verbHandlers.add(DeleteVerbHandler(
      keyStore,
      statsNotificationService,
      notificationManager,
    ));
    _verbHandlers.add(StatsVerbHandler(keyStore));
    _verbHandlers
        .add(ConfigVerbHandler(keyStore, commitLog: _commitLogOverride));
    _verbHandlers.add(MonitorVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(StreamVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(NotifyVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(NotifyListVerbHandler(
      keyStore,
      notificationManager,
    ));
    _verbHandlers.add(BatchVerbHandler(keyStore, this));
    _verbHandlers.add(NotifyStatusVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(NotifyAllVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(
        SyncProgressiveVerbHandler(keyStore, commitLog: _commitLogOverride));
    _verbHandlers.add(InfoVerbHandler(keyStore));
    _verbHandlers.add(NoOpVerbHandler(keyStore));
    _verbHandlers.add(NotifyRemoveVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(NotifyFetchVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(
        EnrollVerbHandler(keyStore, enrollmentManager, notificationManager));
    _verbHandlers.add(OtpVerbHandler(keyStore));
    _verbHandlers.add(KeysVerbHandler(keyStore, enrollmentManager, atSign));
    return _verbHandlers;
  }
}
