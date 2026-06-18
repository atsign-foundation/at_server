import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/manager/response_handler_manager.dart';

/// Server-scoped collaborators injected into every verb handler at construction
/// time, so a handler's dependencies are explicit at its construction site
/// rather than reached for via singletons / global state ("spooky action at a
/// distance").
///
/// Built once in [AtSecondaryServerImpl.start] after its collaborators exist,
/// then passed to [DefaultVerbHandlerManager] and on to each handler via
/// [AbstractVerbHandler]. Membership grows as further singletons are converted.
class VerbHandlerContext {
  /// The atSign this server hosts.
  final Atsign currentAtSign;

  /// Routes a verb to its response handler (formerly the
  /// `DefaultResponseHandlerManager` singleton).
  final ResponseHandlerManager responseManager;

  VerbHandlerContext({
    required this.currentAtSign,
    required this.responseManager,
  });
}
