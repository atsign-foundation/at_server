import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/verb_handler_context.dart';
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

  final AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
  final OutboundClientManager outboundClientManager;
  final AtCacheManager cacheManager;
  final NotificationManager notificationManager;
  final StatsNotificationService statsNotificationService;
  final EnrollmentManager enrollmentManager;
  final AtCommitLog commitLog;
  final AtAccessLog accessLog;
  late final Atsign atSign;
  final VerbHandlerContext context;

  DefaultVerbHandlerManager(
    this.keyStore,
    this.outboundClientManager,
    this.cacheManager,
    this.statsNotificationService,
    this.notificationManager,
    this.enrollmentManager,
    String atSign, {
    required this.commitLog,
    required this.accessLog,
    required this.context,
  }) {
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
    _verbHandlers.add(FromVerbHandler(keyStore, context,
        commitLog: commitLog, accessLog: accessLog));
    _verbHandlers.add(CramVerbHandler(keyStore, context, accessLog: accessLog));
    _verbHandlers.add(PkamVerbHandler(keyStore, context));
    _verbHandlers.add(UpdateVerbHandler(
      keyStore,
      context,
      statsNotificationService,
      notificationManager,
      atSign,
    ));
    _verbHandlers.add(UpdateMetaVerbHandler(
      keyStore,
      context,
      statsNotificationService,
      notificationManager,
      atSign,
    ));
    _verbHandlers
        .add(LocalLookupVerbHandler(keyStore, context, enrollmentManager));
    _verbHandlers.add(ProxyLookupVerbHandler(
      keyStore,
      context,
      outboundClientManager,
      cacheManager,
      accessLog: accessLog,
    ));
    _verbHandlers.add(LookupVerbHandler(
      keyStore,
      context,
      outboundClientManager,
      cacheManager,
      enrollmentManager,
      accessLog: accessLog,
    ));
    _verbHandlers.add(ScanVerbHandler(
      keyStore,
      context,
      outboundClientManager,
      cacheManager,
    ));
    _verbHandlers.add(PolVerbHandler(
      keyStore,
      context,
      outboundClientManager,
      cacheManager,
      accessLog: accessLog,
    ));
    _verbHandlers.add(DeleteVerbHandler(
      keyStore,
      context,
      statsNotificationService,
      notificationManager,
    ));
    _verbHandlers.add(StatsVerbHandler(keyStore, context));
    _verbHandlers
        .add(ConfigVerbHandler(keyStore, context, commitLog: commitLog));
    _verbHandlers
        .add(MonitorVerbHandler(keyStore, context, notificationManager));
    _verbHandlers
        .add(StreamVerbHandler(keyStore, context, notificationManager));
    _verbHandlers
        .add(NotifyVerbHandler(keyStore, context, notificationManager));
    _verbHandlers.add(NotifyListVerbHandler(
      keyStore,
      context,
      notificationManager,
    ));
    _verbHandlers.add(BatchVerbHandler(keyStore, context, this));
    _verbHandlers
        .add(NotifyStatusVerbHandler(keyStore, context, notificationManager));
    _verbHandlers
        .add(NotifyAllVerbHandler(keyStore, context, notificationManager));
    _verbHandlers.add(
        SyncProgressiveVerbHandler(keyStore, context, commitLog: commitLog));
    _verbHandlers.add(InfoVerbHandler(keyStore, context));
    _verbHandlers.add(NoOpVerbHandler(keyStore, context));
    _verbHandlers
        .add(NotifyRemoveVerbHandler(keyStore, context, notificationManager));
    _verbHandlers
        .add(NotifyFetchVerbHandler(keyStore, context, notificationManager));
    _verbHandlers.add(EnrollVerbHandler(
        keyStore, context, enrollmentManager, notificationManager));
    _verbHandlers.add(OtpVerbHandler(keyStore, context));
    _verbHandlers
        .add(KeysVerbHandler(keyStore, context, enrollmentManager, atSign));
    return _verbHandlers;
  }
}
