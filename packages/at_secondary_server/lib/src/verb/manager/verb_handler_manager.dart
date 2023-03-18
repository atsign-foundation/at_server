import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/info_verb_handler.dart';
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
  DefaultVerbHandlerManager(this.keyStore, this.outboundClientManager, this.cacheManager, this.notificationManager) {
    _loadVerbHandlers();
  }

  void close() {

  }

  ///Accepts the command in UTF-8 format and returns the appropriate verbHandler.
  ///@param - utf8EncodedCommand: command in UTF-8 format.
  ///@return - VerbHandler: returns the appropriate verb handler.
  @override
  VerbHandler? getVerbHandler(String utf8EncodedCommand) {
    for (var handler in _verbHandlers) {
      if (handler.accept(utf8EncodedCommand)) {
        if (handler is MonitorVerbHandler) {
          return handler.clone();
        }
        return handler;
      }
    }
    return null;
  }

  List<VerbHandler> _loadVerbHandlers() {
    _verbHandlers = [];
    _verbHandlers.add(FromVerbHandler(keyStore));
    _verbHandlers.add(CramVerbHandler(keyStore));
    _verbHandlers.add(PkamVerbHandler(keyStore));
    _verbHandlers.add(UpdateVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(UpdateMetaVerbHandler(keyStore, notificationManager));
    _verbHandlers.add(LocalLookupVerbHandler(keyStore));
    _verbHandlers.add(ProxyLookupVerbHandler(keyStore, outboundClientManager, cacheManager));
    _verbHandlers.add(LookupVerbHandler(keyStore, outboundClientManager, cacheManager));
    _verbHandlers.add(ScanVerbHandler(keyStore, outboundClientManager, cacheManager));
    _verbHandlers.add(PolVerbHandler(keyStore, outboundClientManager, cacheManager));
    _verbHandlers.add(DeleteVerbHandler(keyStore));
    _verbHandlers.add(StatsVerbHandler(keyStore));
    _verbHandlers.add(ConfigVerbHandler(keyStore));
    _verbHandlers.add(MonitorVerbHandler(keyStore));
    _verbHandlers.add(StreamVerbHandler(keyStore));
    _verbHandlers.add(NotifyVerbHandler(keyStore));
    _verbHandlers.add(NotifyListVerbHandler(keyStore, outboundClientManager));
    _verbHandlers.add(BatchVerbHandler(keyStore, this));
    _verbHandlers.add(NotifyStatusVerbHandler(keyStore));
    _verbHandlers.add(NotifyAllVerbHandler(keyStore));
    _verbHandlers.add(SyncProgressiveVerbHandler(keyStore));
    _verbHandlers.add(InfoVerbHandler(keyStore));
    _verbHandlers.add(NoOpVerbHandler(keyStore));
    _verbHandlers.add(NotifyRemoveVerbHandler(keyStore));
    _verbHandlers.add(NotifyFetchVerbHandler(keyStore));
    return _verbHandlers;
  }
}
