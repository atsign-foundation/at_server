import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The scenarios of docs/projects/gatekeeper/features/namespace_less.feature
/// whose observable is one atServer's answer to an exchange from another
/// atSign, each under its scenario's title.
void main() {
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

  Future<String?> sends(Atsign other, String command) async {
    inboundConnection.metadata
      ..isAuthenticated = false
      ..isPolAuthenticated = true
      ..fromAtSign = other;
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

  Future<void> quarantinedAndAdmittedNowhere(Atsign other) async {
    await gate().setRule('invitations.chat', GateMode.open);
    expect(gate().check('invitations.chat', other), GateVerdict.quarantined);
    expect(gate().isAdmittedSomewhere(other), isFalse);
  }

  test(
      'Admissions recorded beneath a rule do not count as admitted somewhere',
      () async {
    await gate().setRule('chat', GateMode.closed, admit: carol);
    await gate().admit('invitations.chat', dave);
    await keyValueStore.put('@dave:shared_key$alice', AtData()..data = 'key');
    expect(await refusalCode(dave, 'lookup:shared_key@alice'), 'AT0033');
  });

  group('An atSign admitted somewhere may look up the shared key', () {
    for (final String command in [
      'lookup:shared_key@alice',
      'lookup:all:shared_key@alice',
    ]) {
      test(command, () async {
        await gate().setRule('chat', GateMode.closed, admit: dave);
        await keyValueStore.put(
            '@dave:shared_key$alice', AtData()..data = 'the shared key');
        expect(await sends(dave, command), contains('the shared key'));
      });
    }
  });

  test('An atSign admitted only atSign-wide may look up the shared key',
      () async {
    await gate().admit(Gatekeeper.everyNamespace, dave);
    await keyValueStore.put(
        '@dave:shared_key$alice', AtData()..data = 'the shared key');
    expect(await sends(dave, 'lookup:shared_key@alice'), 'the shared key');
  });

  test('A quarantined atSign may not look up the shared key', () async {
    await quarantinedAndAdmittedNowhere(chuck);
    await keyValueStore.put('@chuck:shared_key$alice', AtData()..data = 'key');
    expect(await refusalCode(chuck, 'lookup:shared_key@alice'), 'AT0033');
  });

  test("An admitted atSign's shared-key notification is cached", () async {
    await gate().setRule('chat', GateMode.closed, admit: dave);
    expect(
        await sends(dave,
            'notify:id:1:update:ttr:3888000:@alice:shared_key@dave:encrypted'),
        'data:success');
    expect(await keyValueStore.exists('cached:@alice:shared_key@dave'), isTrue);
  });

  test("An admitted atSign's shared-key delete removes the cached copy",
      () async {
    await gate().setRule('chat', GateMode.closed, admit: dave);
    await keyValueStore.put(
        'cached:@alice:shared_key@dave',
        AtData()
          ..data = 'encrypted'
          ..metaData = (AtMetaData()..isCascade = true));
    expect(
        await sends(dave,
            'notify:id:2:delete:ttr:3888000:ccd:true:@alice:shared_key@dave'),
        'data:success');
    expect(
        await keyValueStore.exists('cached:@alice:shared_key@dave'), isFalse);
  });

  test('A shared-key notification from an atSign admitted nowhere is refused',
      () async {
    await quarantinedAndAdmittedNowhere(chuck);
    expect(
        await refusalCode(chuck,
            'notify:id:3:update:ttr:3888000:@alice:shared_key@chuck:encrypted'),
        'AT0033');
    expect(
        await keyValueStore.exists('cached:@alice:shared_key@chuck'), isFalse);
  });

  test(
      "A shared-key notification for another atSign's key is refused, even"
      ' from an admitted atSign', () async {
    await gate().setRule('chat', GateMode.closed, admit: chuck);
    await keyValueStore.put(
        'cached:@alice:shared_key@dave', AtData()..data = 'earlier');
    expect(
        await refusalCode(chuck,
            'notify:id:7:update:ttr:3888000:@alice:shared_key@dave:encrypted'),
        'AT0009');
    expect((await keyValueStore.get('cached:@alice:shared_key@dave'))!.data,
        'earlier');
  });

  test('A text notification from an atSign admitted somewhere is accepted',
      () async {
    await gate().setRule('chat', GateMode.closed, admit: dave);
    expect(await sends(dave, 'notify:id:4:messageType:text:@alice:hello'),
        'data:success');
  });

  test('A text notification from a quarantined atSign is refused', () async {
    await quarantinedAndAdmittedNowhere(chuck);
    expect(
        await refusalCode(chuck, 'notify:id:5:messageType:text:@alice:hello'),
        'AT0033');
  });

  test(
      'Any other namespace-less key is refused in a notification, even from an'
      ' admitted atSign', () async {
    await gate().setRule('chat', GateMode.closed, admit: dave);
    expect(
        await refusalCode(
            dave, 'notify:id:6:update:ttr:60000:@alice:location@dave:a value'),
        'AT0033');
    expect(await keyValueStore.exists('cached:@alice:location@dave'), isFalse);
  });

  test(
      'Any other namespace-less key is refused in a lookup, even for an'
      ' admitted atSign', () async {
    await gate().setRule('chat', GateMode.closed, admit: dave);
    await keyValueStore.put('@dave:location$alice', AtData()..data = 'here');
    expect(await refusalCode(dave, 'lookup:location@alice'), 'AT0033');
  });
}
