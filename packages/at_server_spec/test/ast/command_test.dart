import 'package:at_server_spec/ast.dart';
import 'package:test/test.dart';

/// One node type: [build] returns a fully populated instance (every field
/// set away from its default), and [variants] changes exactly one field
/// each. Together they check every field participates in `==`.
class NodeCase {
  final String verb;
  final Command Function() build;
  final Map<String, Command> variants;

  NodeCase(this.verb, this.build, this.variants);
}

/// Exhaustive over the sealed hierarchy: adding a node without a case here
/// is a compile error.
String verbOf(Command command) => switch (command) {
      FromCommand() => 'from',
      PolCommand() => 'pol',
      CramCommand() => 'cram',
      PkamCommand() => 'pkam',
      EnrollCommand() => 'enroll',
      OtpCommand() => 'otp',
      KeysCommand() => 'keys',
      UpdateCommand() => 'update',
      UpdateJsonCommand() => 'update:json',
      UpdateMetaCommand() => 'update:meta',
      DeleteCommand() => 'delete',
      LookupCommand() => 'lookup',
      PLookupCommand() => 'plookup',
      LLookupCommand() => 'llookup',
      ScanCommand() => 'scan',
      NotifyCommand() => 'notify',
      NotifyAllCommand() => 'notify:all',
      NotifyListCommand() => 'notify:list',
      NotifyStatusCommand() => 'notify:status',
      NotifyFetchCommand() => 'notify:fetch',
      NotifyRemoveCommand() => 'notify:remove',
      MonitorCommand() => 'monitor',
      StreamCommand() => 'stream',
      SyncFromCommand() => 'sync:from',
      SyncCommand() => 'sync',
      ConfigBlockCommand() => 'config:block',
      ConfigSettingCommand() => 'config',
      StatsCommand() => 'stats',
      InfoCommand() => 'info',
      NoopCommand() => 'noop',
      BatchCommand() => 'batch',
    };

final at = DateTime.utc(2026, 5, 5, 11, 59, 44, 123, 456);
final later = at.add(const Duration(microseconds: 1));

final cases = <NodeCase>[
  NodeCase(
      'from', () => const FromCommand(atSign: 'alice', clientConfig: '{}'), {
    'atSign': const FromCommand(atSign: 'bob', clientConfig: '{}'),
    'clientConfig': const FromCommand(atSign: 'alice'),
  }),
  NodeCase('pol', () => const PolCommand(), {}),
  NodeCase('cram', () => const CramCommand(digest: 'd'), {
    'digest': const CramCommand(digest: 'e'),
  }),
  () {
    PkamCommand b({
      SigningAlgo? s = SigningAlgo.mldsa65,
      HashingAlgo? h = HashingAlgo.sha512,
      String? e = 'id',
      String sig = 'sig',
    }) =>
        PkamCommand(
            signingAlgo: s, hashingAlgo: h, enrollmentId: e, signature: sig);
    return NodeCase('pkam', b, {
      'signingAlgo': b(s: SigningAlgo.eccSecp256r1),
      'hashingAlgo': b(h: null),
      'enrollmentId': b(e: null),
      'signature': b(sig: 'other'),
    });
  }(),
  () {
    EnrollCommand b({
      EnrollOperation op = EnrollOperation.list,
      bool force = true,
      String? ns = '__manage',
      String? params = '{}',
    }) =>
        EnrollCommand(
            operation: op,
            force: force,
            listNamespace: ns,
            enrollParams: params);
    return NodeCase('enroll', b, {
      'operation': b(op: EnrollOperation.listns),
      'force': b(force: false),
      'listNamespace': b(ns: null),
      'enrollParams': b(params: null),
    });
  }(),
  () {
    OtpCommand b(
            {OtpOperation op = OtpOperation.put,
            String? otp = 'ABC123',
            int? ttl = 1000}) =>
        OtpCommand(operation: op, otp: otp, ttl: ttl);
    return NodeCase('otp', b, {
      'operation': b(op: OtpOperation.get),
      'otp': b(otp: null),
      'ttl': b(ttl: null),
    });
  }(),
  () {
    KeysCommand b({
      KeysOperation op = KeysOperation.put,
      KeysVisibility? v = KeysVisibility.private,
      String? ns = 'ns',
      String? app = 'app',
      String? dev = 'dev',
      String? type = 'rsa2048',
      String? enc = 'enc',
      String? name = 'name',
      String value = 'value',
    }) =>
        KeysCommand(
          operation: op,
          visibility: v,
          namespace: ns,
          appName: app,
          deviceName: dev,
          keyType: type,
          encryptionKeyName: enc,
          keyName: name,
          keyValue: value,
        );
    return NodeCase('keys', b, {
      'operation': b(op: KeysOperation.get),
      'visibility': b(v: null),
      'namespace': b(ns: null),
      'appName': b(app: null),
      'deviceName': b(dev: null),
      'keyType': b(type: null),
      'encryptionKeyName': b(enc: null),
      'keyName': b(name: null),
      'keyValue': b(value: ''),
    });
  }(),
  () {
    UpdateCommand b({
      bool nc = true,
      MetadataFragment md = const MetadataFragment(ttl: 1000),
      KeyScope? scope = const SharedWithScope('bob'),
      String key = 'phone',
      String? atSign = 'alice',
      String value = 'hello world',
    }) =>
        UpdateCommand(
            noCommit: nc,
            metadata: md,
            scope: scope,
            atKey: key,
            atSign: atSign,
            value: value);
    return NodeCase('update', b, {
      'noCommit': b(nc: false),
      'metadata': b(md: const MetadataFragment(ttl: 1001)),
      'scope': b(scope: null),
      'atKey': b(key: 'privatekey:at_pkam_publickey'),
      'atSign': b(atSign: null),
      'value': b(value: 'hello'),
    });
  }(),
  NodeCase('update:json',
      () => const UpdateJsonCommand(json: '{"a":1}', noCommit: true), {
    'json': const UpdateJsonCommand(json: '{"a":2}', noCommit: true),
    'noCommit': const UpdateJsonCommand(json: '{"a":1}'),
  }),
  () {
    UpdateMetaCommand b({
      bool nc = true,
      KeyScope? scope = const PublicScope(),
      String key = 'phone',
      String atSign = 'alice',
      MetadataFragment md = const MetadataFragment(isBinary: true),
    }) =>
        UpdateMetaCommand(
            noCommit: nc,
            scope: scope,
            atKey: key,
            atSign: atSign,
            metadata: md);
    return NodeCase('update:meta', b, {
      'noCommit': b(nc: false),
      'scope': b(scope: null),
      'atKey': b(key: 'email'),
      'atSign': b(atSign: 'bob'),
      'metadata': b(md: const MetadataFragment(isBinary: false)),
    });
  }(),
  () {
    DeleteCommand b({
      DateTime? dAt,
      bool nc = true,
      bool force = true,
      Priority? p = Priority.high,
      bool cached = true,
      KeyScope? scope = const SharedWithScope('bob'),
      String key = 'phone',
      String? atSign = 'alice',
    }) =>
        DeleteCommand(
          deletedAt: dAt ?? at,
          noCommit: nc,
          force: force,
          priority: p,
          cached: cached,
          scope: scope,
          atKey: key,
          atSign: atSign,
        );
    return NodeCase('delete', b, {
      'deletedAt': b(dAt: later),
      'noCommit': b(nc: false),
      'force': b(force: false),
      'priority': b(p: Priority.low),
      'cached': b(cached: false),
      'scope': b(scope: const PublicScope()),
      'atKey': b(key: 'privatekey:at_secret'),
      'atSign': b(atSign: null),
    });
  }(),
  () {
    LookupCommand b(
            {bool? bc = false,
            LookupOperation? op = LookupOperation.all,
            String key = 'phone',
            String atSign = 'bob'}) =>
        LookupCommand(
            bypassCache: bc, operation: op, atKey: key, atSign: atSign);
    return NodeCase('lookup', b, {
      'bypassCache': b(bc: null),
      'operation': b(op: LookupOperation.meta),
      'atKey': b(key: 'email'),
      'atSign': b(atSign: 'carol'),
    });
  }(),
  () {
    PLookupCommand b(
            {bool? bc = true,
            LookupOperation? op = LookupOperation.meta,
            String key = 'a:b',
            String atSign = 'bob'}) =>
        PLookupCommand(
            bypassCache: bc, operation: op, atKey: key, atSign: atSign);
    return NodeCase('plookup', b, {
      'bypassCache': b(bc: false),
      'operation': b(op: null),
      'atKey': b(key: 'a'),
      'atSign': b(atSign: 'carol'),
    });
  }(),
  () {
    LLookupCommand b({
      LookupOperation? op = LookupOperation.meta,
      bool cached = true,
      KeyScope? scope = const PublicScope(),
      String key = 'location',
      String atSign = 'bob',
    }) =>
        LLookupCommand(
            operation: op,
            cached: cached,
            scope: scope,
            atKey: key,
            atSign: atSign);
    return NodeCase('llookup', b, {
      'operation': b(op: LookupOperation.all),
      'cached': b(cached: false),
      'scope': b(scope: null),
      'atKey': b(key: 'phone'),
      'atSign': b(atSign: 'alice'),
    });
  }(),
  () {
    ScanCommand b(
            {bool cl = true,
            bool? hidden = false,
            String? forAtSign = 'bob',
            int? page = 2,
            String? regex = '.wavi'}) =>
        ScanCommand(
            commitLog: cl,
            showHidden: hidden,
            forAtSign: forAtSign,
            page: page,
            regex: regex);
    return NodeCase('scan', b, {
      'commitLog': b(cl: false),
      'showHidden': b(hidden: null),
      'forAtSign': b(forAtSign: null),
      'page': b(page: 3),
      'regex': b(regex: null),
    });
  }(),
  () {
    NotifyCommand b({
      String? id = 'n1',
      NotifyOperation? op = NotifyOperation.update,
      MessageType? mt = MessageType.key,
      Priority? p = Priority.medium,
      NotifyStrategy? s = NotifyStrategy.latest,
      int? latestN = 5,
      String? notifier = 'wavi',
      int? ttln = 100,
      DateTime? eAtn,
      bool eph = true,
      MetadataFragment md = const MetadataFragment(ttr: -1),
      KeyScope scope = const SharedWithScope('bob'),
      String key = 'phone',
      String? atSign = 'alice',
      String? value = 'v',
    }) =>
        NotifyCommand(
          id: id,
          operation: op,
          messageType: mt,
          priority: p,
          strategy: s,
          latestN: latestN,
          notifier: notifier,
          ttln: ttln,
          notificationExpiresAt: eAtn ?? at,
          ephemeral: eph,
          metadata: md,
          scope: scope,
          atKey: key,
          atSign: atSign,
          value: value,
        );
    return NodeCase('notify', b, {
      'id': b(id: null),
      'operation': b(op: NotifyOperation.delete),
      'messageType': b(mt: MessageType.text),
      'priority': b(p: Priority.low),
      'strategy': b(s: NotifyStrategy.all),
      'latestN': b(latestN: 6),
      'notifier': b(notifier: null),
      'ttln': b(ttln: null),
      'notificationExpiresAt': b(eAtn: later),
      'ephemeral': b(eph: false),
      'metadata': b(md: const MetadataFragment()),
      'scope': b(scope: const PublicScope()),
      'atKey': b(key: 'email'),
      'atSign': b(atSign: null),
      'value': b(value: null),
    });
  }(),
  () {
    NotifyAllCommand b({
      NotifyOperation? op = NotifyOperation.update,
      MessageType? mt = MessageType.text,
      int? ttl = 1,
      int? ttb = 2,
      int? ttr = -1,
      bool? ccd = false,
      List<String> to = const ['bob', 'carol'],
      String key = 'phone',
      String? atSign = 'alice',
      String? value = 'v',
    }) =>
        NotifyAllCommand(
          operation: op,
          messageType: mt,
          ttl: ttl,
          ttb: ttb,
          ttr: ttr,
          ccd: ccd,
          forAtSigns: to,
          atKey: key,
          atSign: atSign,
          value: value,
        );
    return NodeCase('notify:all', b, {
      'operation': b(op: null),
      'messageType': b(mt: MessageType.key),
      'ttl': b(ttl: null),
      'ttb': b(ttb: null),
      'ttr': b(ttr: 0),
      'ccd': b(ccd: true),
      'forAtSigns (order)': b(to: const ['carol', 'bob']),
      'forAtSigns (length)': b(to: const ['bob']),
      'atKey': b(key: 'email'),
      'atSign': b(atSign: null),
      'value': b(value: null),
    });
  }(),
  () {
    NotifyListCommand b(
            {String? from = '2026-1-',
            String? to = '2026-12-31',
            String? re = '.*'}) =>
        NotifyListCommand(fromDate: from, toDate: to, regex: re);
    return NodeCase('notify:list', b, {
      'fromDate': b(from: null),
      'toDate': b(to: null),
      'regex': b(re: null),
    });
  }(),
  NodeCase(
      'notify:status', () => const NotifyStatusCommand(notificationId: 'a'), {
    'notificationId': const NotifyStatusCommand(notificationId: 'b'),
  }),
  NodeCase('notify:fetch', () => const NotifyFetchCommand(notificationId: 'a'),
      {'notificationId': const NotifyFetchCommand(notificationId: 'b')}),
  NodeCase('notify:remove', () => const NotifyRemoveCommand(id: 'a'),
      {'id': const NotifyRemoveCommand(id: 'b')}),
  () {
    MonitorCommand b(
            {bool strict = true,
            bool self = true,
            bool mux = true,
            int? epoch = 1700000000000,
            String? re = '.wavi'}) =>
        MonitorCommand(
            strict: strict,
            selfNotifications: self,
            multiplexed: mux,
            epochMillis: epoch,
            regex: re);
    return NodeCase('monitor', b, {
      'strict': b(strict: false),
      'selfNotifications': b(self: false),
      'multiplexed': b(mux: false),
      'epochMillis': b(epoch: null),
      'regex': b(re: null),
    });
  }(),
  () {
    StreamCommand b({
      StreamOperation? op = StreamOperation.init,
      String? receiver = 'bob',
      String? ns = 'wavi',
      int? start = 10,
      String? id = 's1',
      String? file = 'a.txt',
      int? length = 100,
    }) =>
        StreamCommand(
          operation: op,
          receiver: receiver,
          namespace: ns,
          startByte: start,
          streamId: id,
          fileName: file,
          length: length,
        );
    return NodeCase('stream', b, {
      'operation': b(op: StreamOperation.resume),
      'receiver': b(receiver: null),
      'namespace': b(ns: null),
      'startByte': b(start: null),
      'streamId': b(id: null),
      'fileName': b(file: null),
      'length': b(length: null),
    });
  }(),
  () {
    SyncFromCommand b(
            {int seq = -1,
            int? limit = 10,
            int? skip = 5,
            String? re = '.*'}) =>
        SyncFromCommand(
            fromCommitSeq: seq,
            limit: limit,
            skipDeletesUntil: skip,
            regex: re);
    return NodeCase('sync:from', b, {
      'fromCommitSeq': b(seq: 0),
      'limit': b(limit: null),
      'skipDeletesUntil': b(skip: null),
      'regex': b(re: null),
    });
  }(),
  NodeCase('sync', () => const SyncCommand(fromCommitSeq: 3, regex: '.*'), {
    'fromCommitSeq': const SyncCommand(fromCommitSeq: 4, regex: '.*'),
    'regex': const SyncCommand(fromCommitSeq: 3),
  }),
  NodeCase(
      'config:block',
      () => ConfigBlockCommand(
          operation: BlockOperation.add, atSigns: ['bob', 'carol']),
      {
        'operation': ConfigBlockCommand(
            operation: BlockOperation.remove, atSigns: ['bob', 'carol']),
        'atSigns':
            ConfigBlockCommand(operation: BlockOperation.add, atSigns: ['bob']),
      }),
  NodeCase(
      'config',
      () => const ConfigSettingCommand(
          operation: ConfigSettingOperation.set, configNew: 'a=1'),
      {
        'operation': const ConfigSettingCommand(
            operation: ConfigSettingOperation.reset, configNew: 'a=1'),
        'configNew': const ConfigSettingCommand(
            operation: ConfigSettingOperation.set, configNew: 'a=2'),
      }),
  NodeCase('stats', () => StatsCommand(statIds: [1, 3], regex: '.*'), {
    'statIds': StatsCommand(statIds: [3, 1], regex: '.*'),
    'regex': StatsCommand(statIds: [1, 3]),
  }),
  NodeCase('info', () => const InfoCommand(mode: InfoMode.brief), {
    'mode': const InfoCommand(),
  }),
  NodeCase('noop', () => const NoopCommand(delayMillis: 100),
      {'delayMillis': const NoopCommand(delayMillis: 101)}),
  NodeCase('batch', () => const BatchCommand(json: '[]'),
      {'json': const BatchCommand(json: '[{}]')}),
];

void main() {
  test('one case per node type', () {
    final verbs = cases.map((c) => verbOf(c.build())).toList();
    expect(verbs, cases.map((c) => c.verb).toList());
    expect(verbs.toSet(), hasLength(31));
  });

  for (final c in cases) {
    group(c.verb, () {
      test('equal to an identically built copy', () {
        expect(c.build(), equals(c.build()));
        expect(c.build().hashCode, c.build().hashCode);
      });

      test('every field participates in equality', () {
        c.variants.forEach((field, variant) {
          expect(variant.runtimeType, c.build().runtimeType);
          expect(c.build(), isNot(equals(variant)),
              reason: '$field should affect ==');
        });
      });

      test('toString names every varied field', () {
        final text = c.build().toString();
        for (final field in c.variants.keys) {
          expect(text, contains('${field.split(' ').first}:'));
        }
      });
    });
  }

  test('distinct node types never compare equal', () {
    final built = cases.map((c) => c.build()).toList();
    for (var i = 0; i < built.length; i++) {
      for (var j = i + 1; j < built.length; j++) {
        expect(built[i], isNot(equals(built[j])));
      }
    }
    // Same field values, different verb.
    expect(const LookupCommand(atKey: 'k', atSign: 'a'),
        isNot(equals(const PLookupCommand(atKey: 'k', atSign: 'a'))));
    expect(const NotifyStatusCommand(notificationId: 'x'),
        isNot(equals(const NotifyFetchCommand(notificationId: 'x'))));
  });

  group('list-valued fields', () {
    test('compare by content, not identity', () {
      expect(StatsCommand(statIds: [1, 2]), StatsCommand(statIds: [1, 2]));
      expect(StatsCommand(statIds: [1, 2]).hashCode,
          StatsCommand(statIds: [1, 2]).hashCode);
    });

    test('are copied and unmodifiable', () {
      final ids = [1, 2];
      final command = StatsCommand(statIds: ids);
      ids.add(3);
      expect(command.statIds, [1, 2]);
      expect(() => command.statIds.add(4), throwsUnsupportedError);
      expect(
          () => NotifyAllCommand(forAtSigns: ['bob'], atKey: 'k')
              .forAtSigns
              .add('x'),
          throwsUnsupportedError);
      expect(
          () => ConfigBlockCommand(operation: BlockOperation.show)
              .atSigns
              .add('x'),
          throwsUnsupportedError);
    });
  });

  test('SigningAlgo carries its wire spelling', () {
    expect(SigningAlgo.values.map((a) => a.wire),
        ['rsa2048', 'ecc_secp256r1', 'mldsa65']);
  });
}
