import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/config/at_config.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

import '../test_utils.dart';

/// The scenarios of docs/projects/gatekeeper/features/rules.feature whose
/// observable is one atServer's answer to an exchange from another atSign,
/// each under its scenario's title.
void main() {
  final Atsign bob = '@bob'.toAtsign();
  final Atsign carol = '@carol'.toAtsign();
  final Atsign chuck = '@chuck'.toAtsign();
  final Atsign dave = '@dave'.toAtsign();

  late NotifyVerbHandler notifyHandler;
  late LookupVerbHandler lookupHandler;
  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    notifyHandler = NotifyVerbHandler(keyValueStore, notificationManager);
    lookupHandler = LookupVerbHandler(
        keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
        accessLog: atAccessLog);
    await gate().setDefault(GateDefault.closed);
  });

  tearDown(() async => await verbTestsTearDown());

  void fromAtServerOf(Atsign other) => inboundConnection.metadata
    ..isAuthenticated = false
    ..isPolAuthenticated = true
    ..fromAtSign = other;

  Future<String?> sends(Atsign other, String command) async {
    fromAtServerOf(other);
    final handler =
        command.startsWith('notify:') ? notifyHandler : lookupHandler;
    return (await handler.processInternal(command, inboundConnection)).data;
  }

  Future<String?> refusalCode(Atsign other, String command) async {
    try {
      await sends(other, command);
    } on Exception catch (e) {
      return GlobalExceptionHandler.getInstance().getErrorCode(e);
    }
    fail('"$command" was not refused');
  }

  group('A closed namespace refuses an atSign it has not admitted', () {
    for (final String command in [
      'notify:id:1:@alice:msg.chat@chuck',
      'lookup:status.chat@alice',
      'lookup:all:status.chat@alice',
    ]) {
      test(command, () async {
        await gate().setRule('chat', GateMode.closed, admit: bob);
        await keyValueStore.put(
            '@chuck:status.chat$alice', AtData()..data = 'for chuck');
        expect(await refusalCode(chuck, command), 'AT0033');
      });
    }
  });

  test('A closed namespace accepts an atSign it has admitted', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(await sends(bob, 'notify:id:2:@alice:msg.chat@bob'), 'data:success');
  });

  test(
      'A value reference resolves only into a namespace where the atSign is'
      ' admitted', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await keyValueStore.put('@bob:card.chat$alice',
        AtData()..data = 'atsign://photo.photos$alice');
    await keyValueStore.put(
        '@bob:photo.photos$alice', AtData()..data = 'the photo');
    expect(await sends(bob, 'lookup:card.chat@alice'), isNull);
  });

  test(
      'A value reference into a namespace where the atSign is admitted'
      ' resolves as today', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await gate().setRule('photos', GateMode.closed, admit: bob);
    await keyValueStore.put('@bob:card.chat$alice',
        AtData()..data = 'atsign://photo.photos$alice');
    await keyValueStore.put(
        '@bob:photo.photos$alice', AtData()..data = 'the photo');
    expect(await sends(bob, 'lookup:card.chat@alice'), 'the photo');
  });

  test('An open namespace refuses an atSign denied there', () async {
    await gate().setRule('photos', GateMode.open);
    await gate().deny('photos', chuck);
    expect(await refusalCode(chuck, 'notify:id:3:@alice:pic.photos@chuck'),
        'AT0033');
  });

  test('A blocklisted atSign is refused at from:, whatever the namespace',
      () async {
    await gate().setRule('photos', GateMode.open);
    await AtConfig(keyValueStore, alice).addToBlockList({'$chuck'});
    final _ClosingConnection connection = _ClosingConnection();
    Exception? refused;
    try {
      await FromVerbHandler(keyValueStore,
              commitLog: atCommitLog, accessLog: atAccessLog)
          .processInternal('from:@chuck', connection);
    } on Exception catch (e) {
      refused = e;
    }
    expect(GlobalExceptionHandler.getInstance().getErrorCode(refused!),
        'AT0013');
    await GlobalExceptionHandler.getInstance()
        .handle(refused, atConnection: connection);
    expect(connection.closed, isTrue);
  });

  test("A notification between @alice's own clients is never gated",
      () async {
    await gate().setRule('chat', GateMode.closed);
    inboundConnection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.cram
      ..isPolAuthenticated = false
      ..enrollmentId = null;
    final String? id = (await notifyHandler.processInternal(
            'notify:@alice:msg.chat@alice', inboundConnection))
        .data;
    expect(id, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });

  test('Admission in one namespace does not carry to another', () async {
    await gate().setRule('chat', GateMode.open, admit: bob);
    await gate().setRule('photos', GateMode.open);
    expect(await sends(bob, 'notify:id:4:@alice:pic.photos@bob'),
        'data:success');
    expect(gate().check('photos', bob), GateVerdict.quarantined);
  });

  test('The atSign-wide admitted set admits in every open namespace',
      () async {
    await gate().setRule('photos', GateMode.open);
    await gate().admit(Gatekeeper.everyNamespace, bob);
    expect(await sends(bob, 'notify:id:5:@alice:pic.photos@bob'),
        'data:success');
    expect(gate().check('photos', bob), GateVerdict.admitted);
  });

  test('The atSign-wide admitted set does not open a closed namespace',
      () async {
    await gate().setRule('sshnp', GateMode.closed, admit: carol);
    await gate().admit(Gatekeeper.everyNamespace, bob);
    expect(await refusalCode(bob, 'notify:id:6:@alice:req.sshnp@bob'),
        'AT0033');
  });

  test("A namespace's deny overrides the atSign-wide admitted set", () async {
    await gate().setRule('photos', GateMode.open);
    await gate().deny('photos', bob);
    await gate().admit(Gatekeeper.everyNamespace, bob);
    expect(await refusalCode(bob, 'notify:id:7:@alice:pic.photos@bob'),
        'AT0033');
  });

  test('A rule covers the namespaces beneath it', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(await refusalCode(chuck, 'notify:id:8:@alice:msg.group.chat@chuck'),
        'AT0033');
  });

  test('The more specific rule decides', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    await gate().setRule('invitations.chat', GateMode.open);
    expect(
        await sends(chuck, 'notify:id:9:@alice:inv1.invitations.chat@chuck'),
        'data:success');
    expect(gate().check('invitations.chat', chuck), GateVerdict.quarantined);
  });

  test('Under the ungated default, a namespace without a rule passes as today',
      () async {
    await gate().setDefault(GateDefault.ungated);
    expect(
        await sends(chuck,
            'notify:id:10:update:ttr:60000:@alice:pic.photos@chuck:a value'),
        'data:success');
    expect(await keyValueStore.exists('cached:@alice:pic.photos@chuck'),
        isTrue);
  });

  test('Under the ungated default, namespace-less traffic passes as today',
      () async {
    await gate().setDefault(GateDefault.ungated);
    expect(await sends(chuck, 'notify:id:11:messageType:text:@alice:hello'),
        'data:success');
  });

  test('Under the ungated default, a namespace with a rule is gated', () async {
    await gate().setDefault(GateDefault.ungated);
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(await refusalCode(chuck, 'notify:id:12:@alice:msg.chat@chuck'),
        'AT0033');
  });

  test('Under the closed default, a namespace without a rule is closed',
      () async {
    expect(await refusalCode(chuck, 'notify:id:13:@alice:pic.photos@chuck'),
        'AT0033');
  });

  test(
      'Under the closed default, a namespace without a rule admits the atSigns'
      ' recorded there', () async {
    await gate().admit('chat', bob);
    expect(
        await sends(bob, 'notify:id:17:@alice:msg.chat@bob'), 'data:success');
  });

  test('Admissions recorded without a rule cover the namespaces beneath',
      () async {
    await gate().admit('chat', bob);
    expect(await sends(bob, 'notify:id:18:@alice:msg.group.chat@bob'),
        'data:success');
  });

  test('Admissions recorded on the namespaces covering a key add up',
      () async {
    await gate().admit('chat', bob);
    await gate().admit('invitations.chat', dave);
    expect(await sends(bob, 'notify:id:19:@alice:inv1.invitations.chat@bob'),
        'data:success');
  });

  test('A rule set beneath admissions recorded above it starts from its own',
      () async {
    await gate().admit('chat', bob);
    await gate().setRule('invitations.chat', GateMode.closed);
    expect(
        await refusalCode(bob, 'notify:id:23:@alice:inv1.invitations.chat@bob'),
        'AT0033');
  });

  test(
      'Under the closed default, the atSign-wide admitted set reaches a'
      ' namespace without a rule', () async {
    await gate().admit(Gatekeeper.everyNamespace, bob);
    expect(await sends(bob, 'notify:id:24:@alice:pic.photos@bob'),
        'data:success');
  });

  test('A rule decides over admissions recorded beneath it', () async {
    await gate().setRule('chat', GateMode.closed, admit: carol);
    await gate().admit('invitations.chat', dave);
    expect(
        await refusalCode(
            dave, 'notify:id:20:@alice:inv1.invitations.chat@dave'),
        'AT0033');
  });

  test(
      'Under the ungated default, admissions recorded beneath a rule leave it'
      ' in force', () async {
    await gate().setDefault(GateDefault.ungated);
    await gate().setRule('chat', GateMode.closed, admit: carol);
    await gate().admit('invitations.chat', dave);
    expect(
        await refusalCode(
            chuck, 'notify:id:21:@alice:inv1.invitations.chat@chuck'),
        'AT0033');
  });

  test(
      'Under the closed default, namespace-less traffic follows its own short'
      ' list', () async {
    expect(
        await refusalCode(chuck, 'notify:id:14:messageType:text:@alice:hello'),
        'AT0033');
  });

  test(
      'A namespace reopened refuses the atSigns it denied before it was closed',
      () async {
    await gate().setRule('photos', GateMode.open);
    await gate().deny('photos', chuck);
    await gate().setRule('photos', GateMode.closed);
    await gate().setRule('photos', GateMode.open);
    expect(await refusalCode(chuck, 'notify:id:22:@alice:pic.photos@chuck'),
        'AT0033');
  });

  test('A rule change applies to a connection already open', () async {
    await gate().setRule('photos', GateMode.open);
    expect(await sends(chuck, 'notify:id:15a:@alice:pic.photos@chuck'),
        'data:success');
    await gate().setRule('photos', GateMode.closed);
    Exception? refused;
    try {
      await notifyHandler.processInternal(
          'notify:id:15:@alice:pic.photos@chuck', inboundConnection);
    } on Exception catch (e) {
      refused = e;
    }
    expect(refused, isNotNull, reason: 'the notification was accepted');
    expect(GlobalExceptionHandler.getInstance().getErrorCode(refused!),
        'AT0033');
  });

  test(
      'The gate decides on the authenticated atSign, not one named in the'
      ' command', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob);
    expect(await refusalCode(chuck, 'notify:id:16:@alice:msg.chat@bob'),
        'AT0009');
  });
}

/// A connection that records whether it was closed.
class _ClosingConnection extends DummyInboundConnection {
  bool closed = false;

  @override
  Future<void> close() async => closed = true;
}
