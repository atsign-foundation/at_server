import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Full access is keyed on being a CRAM connection, never on carrying no
/// enrollment id.
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
    AtSecondaryServerImpl.getInstance().currentAtSign = alice;
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  late UpdateVerbHandler update;
  late ScanVerbHandler scan;
  late EnrollVerbHandler enroll;

  setUp(() {
    update = UpdateVerbHandler(
        keyValueStore, statsNotificationService, notificationManager, alice);
    scan = ScanVerbHandler(
        keyValueStore, mockOutboundClientManager, cacheManager);
    enroll = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
  });

  setUp(() async {
    await keyValueStore.put('phone.wavi$alice', AtData()..data = 'x');
  });

  void bind({required bool authenticated, AuthType? authType, String? id}) {
    inboundConnection.metaData
      ..isAuthenticated = authenticated
      ..authType = authType;
    inboundConnection.metadata.enrollmentId = id;
  }

  Future<bool> authorised() =>
      update.isAuthorized(inboundConnection.metadata, atKey: 'phone.wavi$alice');

  Future<Response> run(AbstractVerbHandler h, String command) async {
    final r = Response();
    final params = getVerbParam(h.getVerb().syntax(), command)
      ..[paramFullCommandAsReceived] = command;
    try {
      await h.processVerb(r, params, inboundConnection);
    } on AtException catch (e) {
      r.isError = true;
      r.errorMessage = '${e.runtimeType}: ${e.message}';
    }
    return r;
  }

  test('a CRAM connection is authorised for everything (the control)',
      () async {
    bind(authenticated: true, authType: AuthType.cram);

    expect(await authorised(), isTrue);
    expect(await update.isRootPrivilegedConnection(inboundConnection.metadata),
        isTrue);
    expect(await scan.getLocalKeys(inboundConnection.metadata, null, false, alice),
        isNotEmpty);
    expect((await run(enroll, 'enroll:list')).isError, isFalse);
  });

  test('a CRAM connection that has enrolled is still CRAM', () async {
    bind(authenticated: true, authType: AuthType.cram, id: etu.primaryEnId);

    expect(await authorised(), isTrue);
    expect(await update.isRootPrivilegedConnection(inboundConnection.metadata),
        isTrue);
  });

  for (final AuthType other in [AuthType.pkamLegacy, AuthType.apkam]) {
    test('authenticated as $other with no enrollment id is refused everywhere',
        () async {
      // A state no writer produces, refused rather than admitted.
      bind(authenticated: true, authType: other);

      expect(await authorised(), isFalse,
          reason: 'not CRAM and nothing to judge by');
      expect(
          await update.isRootPrivilegedConnection(inboundConnection.metadata),
          isFalse);
      expect(update.isAuthorizedSync(null, null, cram: false, atKey: 'k.wavi'),
          isFalse,
          reason: 'the synchronous check, used by sync, answers the same');
      expect(await scan.getLocalKeys(inboundConnection.metadata, null, false, alice),
          isEmpty,
          reason: 'scan has nothing to filter by, so nothing is visible');
      final list = await run(enroll, 'enroll:list');
      expect(list.isError, isTrue);
      expect(list.errorMessage, contains('requires an enrollment or a CRAM'));
    });
  }

  test('a stale CRAM auth type on a connection no longer authenticated is '
      'not CRAM', () async {
    bind(authenticated: false, authType: AuthType.cram);

    expect(await authorised(), isFalse);
    expect(await update.isRootPrivilegedConnection(inboundConnection.metadata),
        isFalse);
    expect(AbstractVerbHandler.isCramConnection(inboundConnection.metadata),
        isFalse);
  });

  test('an unauthenticated connection reaching a check is refused', () async {
    bind(authenticated: false);

    expect(await authorised(), isFalse);
  });

  test('a connection carrying an enrollment is judged by it, as before',
      () async {
    final scopedId = await etu.createPendingEnrollment(
        appName: 'scoped',
        deviceName: 'device',
        namespaces: {'wavi': 'rw'},
        apkamKeysExpiryDuration: null);
    await etu.approveEnrollment(etu.primaryEnId, scopedId);
    bind(authenticated: true, authType: AuthType.apkam, id: scopedId);

    expect(await authorised(), isTrue, reason: 'wavi is held');
    expect(
        await update.isAuthorized(inboundConnection.metadata,
            atKey: 'phone.buzz$alice'),
        isFalse,
        reason: 'buzz is not');
    final list = await run(enroll, 'enroll:list');
    expect(list.isError, isFalse, reason: list.errorMessage);
    expect((jsonDecode(list.data!) as Map).keys,
        [enMgr.buildEnrollmentKey(scopedId)],
        reason: 'the self-only projection');
  });
}
