import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/info_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/stats_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/sync_progressive_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Every place the server treats a connection carrying no enrollment id
/// specially, stated beside what an enrollment holding `*:rw` and
/// `__manage:rw` gets from the same verb.
///
/// A connection carrying no id is today CRAM, owner and legacy PKAM, and
/// each of these carve-outs was written for that whole company. Stating the
/// two answers side by side is what lets a later change to who carries an id
/// be checked against both: a connection that comes to carry a root
/// enrollment must get what a root gets, and nothing a null id got by
/// accident.
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

  /// The connection as a null-id owner connection.
  void asNullId() {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram;
    inboundConnection.metadata.enrollmentId = null;
  }

  /// The connection as the fixture's root enrollment, which holds `*:rw`
  /// and `__manage:rw`.
  void asRoot() {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = etu.primaryEnId;
  }

  /// An approved enrollment holding `wavi:rw` and nothing else.
  Future<String> scoped() async {
    final String id = await etu.createPendingEnrollment(
        appName: 'scoped',
        deviceName: 'device',
        namespaces: {'wavi': 'rw'},
        apkamKeysExpiryDuration: null);
    await etu.approveEnrollment(etu.primaryEnId, id);
    return id;
  }

  Future<Response> run(handler, String command) async {
    final r = Response();
    final params = getVerbParam(handler.getVerb().syntax(), command)
      ..[paramFullCommandAsReceived] = command;
    await handler.processVerb(r, params, inboundConnection);
    return r;
  }

  group('keys:', () {
    test('a null id is refused outright; a root enrollment is admitted',
        () async {
      final handler = KeysVerbHandler(keyValueStore, enMgr, alice);

      asNullId();
      await expectLater(
          () => run(handler, 'keys:get:self'),
          throwsA(isA<AtEnrollmentException>().having((e) => e.message,
              'message', 'Keys verb cannot be accessed without an enrollmentId')),
          reason: 'today: the verb keys its store by enrollment id and a '
              'connection carrying none has nowhere to look');

      asRoot();
      final r = await run(handler, 'keys:get:self');
      expect(r.isError, isFalse, reason: r.errorMessage);
      expect(jsonDecode(r.data!), isA<List>(),
          reason: 'an enrollment holding __manage is admitted');
    });
  });

  group('info', () {
    test('a null id gets no apkam_metadata; a root enrollment gets its record',
        () async {
      final handler = InfoVerbHandler(keyValueStore);

      asNullId();
      final nullId = await run(handler, 'info');
      expect(jsonDecode(nullId.data!).containsKey('apkam_metadata'), isFalse,
          reason: 'today: no record stands behind a null id');

      asRoot();
      final root = await run(handler, 'info');
      final Map metadata = jsonDecode(root.data!)['apkam_metadata'];
      expect(metadata['namespaces'], {'*': 'rw', '__manage': 'rw'},
          reason: 'an enrollment is served its own record');
    });
  });

  group('sync:from', () {
    test('a null id and a root enrollment are served the same entries',
        () async {
      await keyValueStore.put('public:country.wavi$alice', AtData()..data = 'x');
      await keyValueStore.put('@bob:note.buzz$alice', AtData()..data = 'y');
      await keyValueStore.put('phone.atmosphere$alice', AtData()..data = 'z');
      final handler =
          SyncProgressiveVerbHandler(keyValueStore, commitLog: atCommitLog);
      final params = HashMap<String, String>()
        ..[AtConstants.fromCommitSequence] = '-1';

      asNullId();
      final nullId = Response();
      await handler.processVerb(nullId, params, inboundConnection);
      final List nullIdKeys =
          (jsonDecode(nullId.data!) as List).map((e) => e['atKey']).toList();
      expect(nullIdKeys, hasLength(3),
          reason: 'today: no per-entry check at all for a null id');

      asRoot();
      final root = Response();
      await handler.processVerb(root, params, inboundConnection);
      final List rootKeys =
          (jsonDecode(root.data!) as List).map((e) => e['atKey']).toList();
      expect(rootKeys, nullIdKeys,
          reason: '* covers every namespace, so the per-entry check the '
              'enrollment does go through admits the same entries');

      // The control: the check is real, because a scoped enrollment is
      // served less.
      inboundConnection.metadata.enrollmentId = await scoped();
      final narrowed = Response();
      await handler.processVerb(narrowed, params, inboundConnection);
      final List narrowedKeys = (jsonDecode(narrowed.data!) as List)
          .map((e) => e['atKey'])
          .toList();
      expect(narrowedKeys, isNot(nullIdKeys));
      expect(narrowedKeys, isNot(contains('@bob:note.buzz$alice')));
    });
  });

  group('stats', () {
    test('the last commit id is the same for a null id and a root enrollment',
        () async {
      await keyValueStore.put('public:one.wavi$alice', AtData()..data = 'x');
      await keyValueStore.put('two.buzz$alice', AtData()..data = 'y');
      final handler = StatsVerbHandler(keyValueStore);
      final String last = atCommitLog.lastCommittedSequenceNumber().toString();

      asNullId();
      final nullId = await run(handler, 'stats:3');
      expect(jsonDecode(nullId.data!)[0]['value'], last,
          reason: 'today: an empty enrolled-namespace list restricts nothing');

      asRoot();
      final root = await run(handler, 'stats:3');
      expect(jsonDecode(root.data!)[0]['value'], last,
          reason: '* restricts nothing either');
    });
  });

  group('scan', () {
    test('a null id sees the enrollment records; a root enrollment does not',
        () async {
      // The one carve-out where the two answers DIFFER, and the difference is
      // deliberate: `enroll:list` is the management path for enrollment
      // records, and scan hides them from every enrollment, `*` included.
      await keyValueStore.put('public:seen.wavi$alice', AtData()..data = 'x');
      final handler =
          ScanVerbHandler(keyValueStore, mockOutboundClientManager, cacheManager);
      final String enrollmentKey = enMgr.buildEnrollmentKey(etu.primaryEnId);

      asNullId();
      final nullId = await run(handler, 'scan');
      final List nullIdKeys = jsonDecode(nullId.data!);
      expect(nullIdKeys, contains('public:seen.wavi$alice'));
      expect(nullIdKeys, contains(enrollmentKey),
          reason: 'today: a null id gets the unfiltered list');

      asRoot();
      final root = await run(handler, 'scan');
      final List rootKeys = jsonDecode(root.data!);
      expect(rootKeys, contains('public:seen.wavi$alice'),
          reason: '* covers every ordinary namespace');
      expect(rootKeys, isNot(contains(enrollmentKey)),
          reason: 'and the enrollment records are hidden from every '
              'enrollment; enroll:list is where they are managed');
    });
  });

  group('enroll:list', () {
    test('a null id and a root enrollment get one answer: every record, whole',
        () async {
      await scoped();

      asNullId();
      final Map nullId =
          jsonDecode((await run(etu.evh, 'enroll:list')).data!);

      asRoot();
      final Map root = jsonDecode((await run(etu.evh, 'enroll:list')).data!);

      expect(root, nullId,
          reason: 'the null-id path and the __manage:rw branch project the '
              'same roster the same way: unredacted, every enrollment');
      expect(nullId.length, 2);
      expect(nullId.values.first, contains('encryptedAPKAMSymmetricKey'),
          reason: 'control: the projection really is the whole record');
    });
  });

  group('isRootPrivilegedConnection', () {
    test('a null id is root-privileged; an enrollment is by its grants',
        () async {
      final EnrollVerbHandler handler = etu.evh;

      asNullId();
      expect(await handler.isRootPrivilegedConnection(inboundConnection.metadata),
          isTrue,
          reason: 'today: a connection carrying no id holds the atSign');

      asRoot();
      expect(await handler.isRootPrivilegedConnection(inboundConnection.metadata),
          isTrue);

      inboundConnection.metadata.enrollmentId = await scoped();
      expect(await handler.isRootPrivilegedConnection(inboundConnection.metadata),
          isFalse,
          reason: 'the control: grants decide, not the carrying of an id');

      // A root that has left approved is no longer root-privileged.
      final String rootKey = enMgr.buildEnrollmentKey(etu.primaryEnId);
      final AtData record = (await keyValueStore.get(rootKey))!;
      final EnrollDataStoreValue value =
          EnrollDataStoreValue.fromJson(jsonDecode(record.data!))
            ..approval = EnrollApproval(EnrollmentStatus.revoked.name);
      record.data = jsonEncode(value.toJson());
      await enMgr.put(etu.primaryEnId, record, EnrollmentStatus.revoked);
      asRoot();
      expect(await handler.isRootPrivilegedConnection(inboundConnection.metadata),
          isFalse);
    });
  });

  group('the refusal that names a remedy', () {
    test('an enrollment refused an act on a record holding no namespaces is '
        'told to use CRAM', () async {
      // The remedy names the one connection type that is always exempt. A
      // legacy connection is not named: it is not exempt by being legacy.
      const String emptyId = 'holds-nothing';
      final EnrollDataStoreValue empty =
          EnrollDataStoreValue('s', 'app', 'device', 'pk-empty')
            ..namespaces = {}
            ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await enMgr.put(emptyId, AtData()..data = jsonEncode(empty.toJson()),
          EnrollmentStatus.approved);

      inboundConnection.metadata.enrollmentId = await scoped();
      Object? thrown;
      try {
        await run(etu.evh, 'enroll:revoke:{"enrollmentId":"$emptyId"}');
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<UnAuthorizedException>());
      expect((thrown as UnAuthorizedException).message,
          contains('from a CRAM connection'));
      expect(thrown.message, isNot(contains('owner')));
    });
  });
}
