import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// An atSign of 55 characters after its @.
final Atsign max = '@${'m' * 55}'.toAtsign();

/// An atSign of 56 characters after its @.
final String over = '@${'o' * 56}';

/// What the atServer answers an atSign of more than 55 characters with, on a
/// connection that has not authenticated or on a peer's.
const String tooLongUnauthenticated = 'error:AT0003-Exception: invalid @sign:'
    ' must have at most 55 characters after the @\n@';

/// What the atServer answers an atSign of more than 55 characters with, on
/// @alice's authenticated client's connection.
const String tooLongForAlice = 'error:AT0003-Invalid syntax : invalid @sign:'
    ' must have at most 55 characters after the @\n@alice@';

/// The atDirectory as the outbound clients see it: it holds no atSign.
late MockSecondaryAddressFinder atDirectory;
late OutboundClientManager outbound;
late DefaultVerbHandlerManager verbs;

/// Serves [atSign], as the atServer's own, with the verb handlers it runs.
void serve(Atsign atSign) {
  AtSecondaryServerImpl.getInstance()
    ..currentAtSign = atSign
    ..secondaryAddressFinder = atDirectory;
  outbound = OutboundClientManager(atDirectory, mockOutboundConnectionFactory);
  verbs = DefaultVerbHandlerManager(
    keyValueStore,
    outbound,
    AtCacheManager(atSign, keyValueStore, outbound, notificationManager),
    statsNotificationService,
    notificationManager,
    enMgr,
    atSign,
    commitLog: atCommitLog,
    accessLog: atAccessLog,
  );
}

/// Sends [command] on [connection] as the atServer does: the executor picks
/// the handler, and GlobalExceptionHandler answers whatever it throws.
Future<void> send(String command, FakeInboundConnection connection) async {
  try {
    await DefaultVerbExecutor().execute(command, connection, verbs);
  } on Exception catch (e) {
    await GlobalExceptionHandler.getInstance()
        .handle(e, atConnection: connection);
  }
}

/// A [FakeInboundConnection] that also records the atSign a from: binds it
/// to.
class Connection extends FakeInboundConnection {
  Connection(InboundConnectionMetadata metadata)
      : super(FakeSocket(), metadata);

  String? _initiatedBy;

  @override
  String? get initiatedBy => _initiatedBy;

  @override
  set initiatedBy(String? atSign) => _initiatedBy = atSign;
}

/// A connection that has sent nothing yet.
Connection unauthenticated() => Connection(InboundConnectionMetadata());

/// @alice's authenticated client's connection.
Connection aliceClient() => Connection(InboundConnectionMetadata()
  ..isAuthenticated = true
  ..authType = AuthType.cram);

/// A connection on which [atSign]'s atServer has proved itself by pol.
Connection peer(Atsign atSign) => Connection(InboundConnectionMetadata()
  ..isPolAuthenticated = true
  ..fromAtSign = atSign);

/// The atServer's keys, last commit, access-log entries and notifications.
Future<List<Object?>> footprint() async => [
      (await (await keyValueStore.getKeys()).toList())..sort(),
      atCommitLog.lastCommittedSequenceNumber(),
      atAccessLog.entriesCount(),
      (await notifStore.iterate().toList()).length,
    ];

/// The status of each notification stored for [atSign] to deliver.
Future<List<NotificationStatus?>> sentTo(String atSign) async => [
      await for (final n in notifStore.iterate())
        if (n.type == NotificationType.sent && n.toAtSign == atSign)
          n.notificationStatus
    ];

/// Expects that no outbound client asked the atDirectory for any atSign.
void expectNothingLookedUp() {
  verifyNever(() => atDirectory.findSecondary(any()));
  verifyNever(() => mockSecondaryAddressFinder.findSecondary(any()));
}

/// Opens a fresh store for @alice and serves her, with an atDirectory that
/// holds no atSign, as [serve] does.
Future<void> setUpAtSignBound() async {
  await verbTestsSetUp();
  atDirectory = MockSecondaryAddressFinder();
  when(() => atDirectory.findSecondary(any())).thenAnswer((invocation) async =>
      throw SecondaryNotFoundException(
          'No entry in atDirectory for ${invocation.positionalArguments[0]}'));
  // NOTE delivery waits here, so a queued notification stays queued.
  when(() => mockSecondaryAddressFinder.findSecondary(any(that: isNot(bob))))
      .thenAnswer((_) => Completer<at_lookup.SecondaryAddress>().future);
  serve(alice);
}
