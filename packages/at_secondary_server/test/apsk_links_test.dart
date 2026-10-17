import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/apsk_links.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Catalogue: features/enrollment/apsk_links.feature
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  // Public keys as base64, beside the kid each derives: the first 8 bytes,
  // hex-encoded, of the SHA-256 of the decoded key.
  const String p1 = 'AAEC';
  const String k1 = 'ae4b3280e56e2faf';
  const String p2 = 'CCEC';
  const String k2 = 'f4a1915927abe756';
  const String p3 = 'BBEC';
  const String k3 = '6d88ca9748ee2a19';
  const String k9 = 'e2aae1e175b15d00';
  const String pFbff = '+/8=';
  const String kFbff = 'db8fed54159afe40';

  Map<String, dynamic> entry(String kid, String alg, String pub,
          {String? status}) =>
      {
        'kid': kid,
        'use': 'sign',
        'alg': alg,
        'pub': pub,
        if (status != null) 'status': status,
      };

  Map<String, dynamic> listForm(List<Map<String, dynamic>> entries) =>
      {'v': 1, 'keys': entries};

  final Map<String, dynamic> k1AndK2 =
      listForm([entry(k1, 'mldsa65', p1), entry(k2, 'rsa2048', p2)]);

  Map<String, dynamic> payload(
          String enrollmentId, String kid, String alg, String pub) =>
      {
        'v': 2,
        'enrollmentId': enrollmentId,
        'kid': kid,
        'alg': alg,
        'pub': pub,
      };

  /// A chain link's shape: its payload base64url-encoded, as a JWS carries it.
  Map<String, dynamic> chainLink(Map<String, dynamic> payload,
          {String signature = 'chain signature'}) =>
      {
        'payload': base64Url
            .encode(utf8.encode(jsonEncode(payload)))
            .replaceAll('=', ''),
        'signatures': [
          {
            'protected': 'eyJ0eXAiOiJhdC1jaGFpbi1saW5rK2p3cyJ9',
            'signature': signature
          }
        ],
      };

  /// A root link's shape: its payload a JSON object.
  Map<String, dynamic> rootLink(Map<String, dynamic> payload,
          {String signature = 'root signature'}) =>
      {
        'v': 2,
        'alg': 'mldsa65',
        'kid': 'root kid',
        'payload': payload,
        'signature': signature,
      };

  /// An approved enrollment, admitted by the primary enrollment.
  Future<String> enrollment(String name,
      {Map<String, String> namespaces = const {'buzz': 'rw'},
      Map<String, dynamic>? apsk,
      String? apskLegacy,
      String? apkamPublicKey,
      String? signingAlgo}) async {
    final id = await etu.createPendingEnrollment(
        appName: name,
        deviceName: 'device-$name',
        namespaces: namespaces,
        apkamKeysExpiryDuration: null,
        apsk: apsk,
        apskLegacy: apskLegacy,
        apkamPublicKey: apkamPublicKey,
        signingAlgo: signingAlgo);
    await etu.approveEnrollment(etu.primaryEnId, id);
    return id;
  }

  /// Points [inboundConnection] at [callerId], or at a CRAM connection when
  /// [callerId] is null.
  void connectAs(String? callerId) {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = callerId == null ? AuthType.cram : AuthType.apkam;
    inboundConnection.metadata.enrollmentId = callerId;
  }

  /// Sends `enroll:link` carrying [params] as the wire spells them, as
  /// [callerId], or over CRAM when [callerId] is null.
  Future<Map<String, dynamic>> send(
      String? callerId, Map<String, dynamic> params) async {
    connectAs(callerId);
    final r = Response();
    await etu.evh.processVerb(
        r,
        getVerbParam(VerbSyntax.enroll, 'enroll:link:${jsonEncode(params)}'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
    return jsonDecode(r.data!);
  }

  /// Sends `enroll:link` for [targetId] as [callerId], or over CRAM when
  /// [callerId] is null, carrying [links].
  Future<Map<String, dynamic>> link(
          String? callerId, String targetId, Map<String, dynamic> links) =>
      send(callerId, {'enrollmentId': targetId, 'links': links});

  /// Sends `enroll:update` as [enrollmentId] on itself, republishing [apsk].
  Future<void> republish(String enrollmentId, Map<String, dynamic> apsk) async {
    connectAs(enrollmentId);
    final r = Response();
    await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll,
            'enroll:update:'
            '${jsonEncode({'enrollmentId': enrollmentId, 'apsk': apsk})}'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
  }

  String apskKey(String enrollmentId) =>
      'public:_apsk.$enrollmentId.a.__e$alice';

  /// Puts [value] at [enrollmentId]'s `_apsk` as that enrollment, sending
  /// [ttl] and [appMetadata] when given.
  Future<void> put(String enrollmentId, String value,
      {AppMetadata? appMetadata, int? ttl}) async {
    connectAs(enrollmentId);
    final String withTtl = ttl == null ? '' : 'ttl:$ttl:';
    final String withAppMetadata = appMetadata == null
        ? ''
        : 'appMetadata:${Metadata.encodeAppMetadata(appMetadata)}:';
    final r = Response();
    await etu.uvh.processVerb(
        r,
        getVerbParam(VerbSyntax.update,
            'update:$withTtl$withAppMetadata${apskKey(enrollmentId)} $value'),
        inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
  }

  /// The `_apsk` record stored for [enrollmentId].
  Future<AtData> record(String enrollmentId) async =>
      (await keyValueStore.get(apskKey(enrollmentId)))!;

  /// The link map stored on [enrollmentId]'s `_apsk`, read by its field
  /// name.
  Future<Object?> linksOn(String enrollmentId) async =>
      (await record(enrollmentId))
          .metaData
          ?.appMetadata
          ?.additional?['apskLinks'];

  Matcher refusedNaming<T>(String what) => throwsA(isA<T>()
      .having((e) => (e as AtException).message, 'message', contains(what)));

  group('enroll:link admits only the target or a caller that could approve it',
      () {
    late String b;
    late Map<String, dynamic> k1Link;

    setUp(() async {
      b = await enrollment('b', apsk: k1AndK2);
      k1Link = {
        k1: {'link': chainLink(payload(b, k1, 'mldsa65', p1)), 'expect': null}
      };
    });

    test('C, without __manage, is refused and nothing is written', () async {
      final c = await enrollment('c');
      await expectLater(
          link(c, b, k1Link), throwsA(isA<UnAuthorizedException>()));
      expect(await linksOn(b), isNull);
    });

    test(
        'D, holding __manage but not B\'s namespace at B\'s access, is '
        'refused and nothing is written', () async {
      final d =
          await enrollment('d', namespaces: {'__manage': 'rw', 'buzz': 'r'});
      await expectLater(
          link(d, b, k1Link), throwsA(isA<UnAuthorizedException>()));
      expect(await linksOn(b), isNull);
    });

    test('B, on its own keys, is admitted without __manage', () async {
      expect(await link(b, b, k1Link), {
        'enrollmentId': b,
        'linked': [k1]
      });
      expect(await linksOn(b), {k1: k1Link[k1]['link']});
    });

    test('a caller passing the approve gate is admitted', () async {
      final a =
          await enrollment('a', namespaces: {'__manage': 'rw', 'buzz': 'rw'});
      await link(a, b, k1Link);
      expect(await linksOn(b), {k1: k1Link[k1]['link']});
    });

    test('a CRAM connection is admitted', () async {
      await link(null, b, k1Link);
      expect(await linksOn(b), {k1: k1Link[k1]['link']});
    });
  });

  group('enroll:link checks structure, and writes all or nothing', () {
    late String b;
    late Map<String, dynamic> wellFormedK1;

    setUp(() async {
      b = await enrollment('b', apsk: k1AndK2);
      wellFormedK1 = {
        'link': chainLink(payload(b, k1, 'mldsa65', p1)),
        'expect': null
      };
    });

    final Map<String, (String, Map<String, dynamic> Function(String b))>
        malformed = {
      'a link for an unadvertised K9': (
        k9,
        (b) => {
              k9: {
                'link': chainLink(payload(b, k9, 'mldsa65', p1)),
                'expect': null
              }
            }
      ),
      'a link whose payload names another enrollment': (
        k2,
        (b) => {
              k2: {
                'link': chainLink(payload(etu.primaryEnId, k2, 'rsa2048', p2)),
                'expect': null
              }
            }
      ),
      'a link whose payload names another kid': (
        k2,
        (b) => {
              k2: {
                'link': chainLink(payload(b, k1, 'rsa2048', p2)),
                'expect': null
              }
            }
      ),
      'a link whose payload names another alg': (
        k2,
        (b) => {
              k2: {
                'link': rootLink(payload(b, k2, 'mldsa65', p2)),
                'expect': null
              }
            }
      ),
      'a link whose payload names another public key': (
        k2,
        (b) => {
              k2: {
                'link': rootLink(payload(b, k2, 'rsa2048', p1)),
                'expect': null
              }
            }
      ),
      'a link over 16 KiB': (
        k2,
        (b) => {
              k2: {
                'link': chainLink(payload(b, k2, 'rsa2048', p2),
                    signature: 'x' * (16 * 1024)),
                'expect': null
              }
            }
      ),
      'a link with no payload': (
        k2,
        (b) => {
              k2: {
                'link': {'signature': 'root signature'},
                'expect': null
              }
            }
      ),
    };

    for (final MapEntry(key: String name, value: (String named, bad))
        in malformed.entries) {
      test('$name refuses the call, naming $named, and K1 is not written',
          () async {
        await expectLater(
            link(etu.primaryEnId, b, {k1: wellFormedK1, ...bad(b)}),
            refusedNaming<IllegalArgumentException>(named));
        expect(await linksOn(b), isNull);
      });
    }

    test('a call over the 500 KiB limit is refused, and K1 is not written',
        () async {
      final Map<String, dynamic> filler = {
        for (int i = 0; i < 40; i++)
          'filler$i': {
            'link': {'payload': 'x' * (15 * 1024)},
            'expect': null
          }
      };
      await expectLater(link(etu.primaryEnId, b, {k1: wellFormedK1, ...filler}),
          refusedNaming<IllegalArgumentException>('enrollment record limit'));
      expect(await linksOn(b), isNull);
    });

    test('a kid that carries no expect is refused, and K1 is not written',
        () async {
      await expectLater(
          link(etu.primaryEnId, b, {
            k1: wellFormedK1,
            k2: {'link': rootLink(payload(b, k2, 'rsa2048', p2))}
          }),
          refusedNaming<IllegalArgumentException>(k2));
      expect(await linksOn(b), isNull);
    });

    final Map<String, (String, Map<String, dynamic> Function(String b))>
        malformedCalls = {
      'a call carrying no links': (
        'at least one link',
        (b) => {'enrollmentId': b, 'links': {}}
      ),
      'a call with no links field': (
        'at least one link',
        (b) => {'enrollmentId': b}
      ),
      'a call naming no enrollment': (
        'enrollmentId is mandatory',
        (b) => {
              'links': {
                k1: {
                  'link': chainLink(payload(b, k1, 'mldsa65', p1)),
                  'expect': null
                }
              }
            }
      ),
      'a call whose link is not an object': (
        'and $k1 does not',
        (b) => {
              'enrollmentId': b,
              'links': {
                k1: {'link': 'a link', 'expect': null}
              }
            }
      ),
      'a call whose expect is neither a link nor null': (
        'and $k1 does not',
        (b) => {
              'enrollmentId': b,
              'links': {
                k1: {
                  'link': chainLink(payload(b, k1, 'mldsa65', p1)),
                  'expect': 'a link'
                }
              }
            }
      ),
    };

    for (final MapEntry(key: String name, value: (String message, params))
        in malformedCalls.entries) {
      test('$name is refused, and nothing is written', () async {
        await expectLater(send(etu.primaryEnId, params(b)),
            refusedNaming<IllegalArgumentException>(message));
        expect(await linksOn(b), isNull);
      });
    }

    /// A chain link on B for [kid] whose JSON encoding is [bytes] long.
    Map<String, dynamic> sizedLink(
        String kid, String alg, String pub, int bytes) {
      final int unsigned = utf8
          .encode(
              jsonEncode(chainLink(payload(b, kid, alg, pub), signature: '')))
          .length;
      return chainLink(payload(b, kid, alg, pub),
          signature: 'x' * (bytes - unsigned));
    }

    test('a link of exactly 16 KiB is written, and one a byte longer refused',
        () async {
      final Map<String, dynamic> exact =
          sizedLink(k2, 'rsa2048', p2, 16 * 1024);
      expect(utf8.encode(jsonEncode(exact)).length, 16 * 1024,
          reason: 'precondition: the link is 16 KiB encoded');
      await expectLater(
          link(etu.primaryEnId, b, {
            k2: {
              'link': sizedLink(k2, 'rsa2048', p2, 16 * 1024 + 1),
              'expect': null
            }
          }),
          refusedNaming<IllegalArgumentException>(k2));
      expect(await linksOn(b), isNull);
      await link(etu.primaryEnId, b, {
        k2: {'link': exact, 'expect': null}
      });
      expect(await linksOn(b), {k2: exact});
    });

    test(
        'a call that would take B\'s _apsk record, with every link it would '
        'then hold, over 500 KiB is refused, and nothing is written', () async {
      await put(b, jsonEncode({...k1AndK2, 'padding': 'x' * 410000}),
          appMetadata: AppMetadata(
              providerId: 'acme', additional: {'other': 'y' * 72000}));
      final Map<String, dynamic> k1Link = sizedLink(k1, 'mldsa65', p1, 15000);
      await link(etu.primaryEnId, b, {
        k1: {'link': k1Link, 'expect': null}
      });
      expect(await linksOn(b), {k1: k1Link},
          reason: 'precondition: the record with K1\'s link is under 500 KiB');
      await expectLater(
          link(etu.primaryEnId, b, {
            k2: {'link': sizedLink(k2, 'rsa2048', p2, 16000), 'expect': null}
          }),
          refusedNaming<IllegalArgumentException>('_apsk record would be'));
      expect(await linksOn(b), {k1: k1Link});
    });

    /// Lists, beside K1 and K2, the key 0xfb 0xff spelt as [pub].
    Future<void> listFbffAs(String pub) => put(
        b,
        jsonEncode(listForm([
          entry(k1, 'mldsa65', p1),
          entry(k2, 'rsa2048', p2),
          entry(kFbff, 'mldsa65', pub)
        ])));

    for (final (String form, String pub) in [
      ('in the URL-safe alphabet', '-_8='),
      ('without padding', '+/8'),
      ('with non-zero pad bits', '+/9='),
      ('wrapped in whitespace', ' $pFbff '),
      ('as an empty string', ''),
    ]) {
      test(
          'a link for a key spelt $form refuses the call, naming the key, '
          'and K1 is not written', () async {
        await listFbffAs(pub);
        await expectLater(
            link(etu.primaryEnId, b, {
              k1: wellFormedK1,
              kFbff: {
                'link': chainLink(payload(b, kFbff, 'mldsa65', pub)),
                'expect': null
              }
            }),
            refusedNaming<IllegalArgumentException>(
                'the key $kFbff is not spelt'));
        expect(await linksOn(b), isNull);
      });
    }

    test('a key spelt in padded standard base64 takes a link', () async {
      await listFbffAs(pFbff);
      final Map<String, dynamic> fbffLink =
          chainLink(payload(b, kFbff, 'mldsa65', pFbff));
      await link(etu.primaryEnId, b, {
        kFbff: {'link': fbffLink, 'expect': null}
      });
      expect(await linksOn(b), {kFbff: fbffLink});
    });

    test('a call for a pending enrollment is refused', () async {
      final pending = await etu.createPendingEnrollment(
          appName: 'pending',
          deviceName: 'device-pending',
          namespaces: {'buzz': 'rw'},
          apkamKeysExpiryDuration: null,
          apsk: k1AndK2);
      await expectLater(
          link(etu.primaryEnId, pending, {
            k1: {
              'link': chainLink(payload(pending, k1, 'mldsa65', p1)),
              'expect': null
            }
          }),
          refusedNaming<AtEnrollmentException>('pending'));
    });

    test('a call for a revoked enrollment is refused', () async {
      await etu.revokeEnrollment(etu.primaryEnId, b);
      await expectLater(link(etu.primaryEnId, b, {k1: wellFormedK1}),
          refusedNaming<AtEnrollmentException>('revoked'));
    });

    test('a call carrying well-formed links for K1 and K2 writes both',
        () async {
      final Map<String, dynamic> k2Link =
          rootLink(payload(b, k2, 'rsa2048', p2));
      expect(
          await link(etu.primaryEnId, b, {
            k1: wellFormedK1,
            k2: {'link': k2Link, 'expect': null}
          }),
          {
            'enrollmentId': b,
            'linked': [k1, k2]
          });
      expect(await linksOn(b), {k1: wellFormedK1['link'], k2: k2Link});
      expect((await record(b)).data, jsonEncode(k1AndK2),
          reason: 'a link leaves the advertised value as it was');
      expect((await record(b)).metaData!.appMetadata!.providerId, 'legacy',
          reason: 'appMetadata the atServer creates reads as a record with '
              'none did');
    });

    test(
        'a link leaves the record\'s value, its other appMetadata and its '
        'expiry as they were', () async {
      await put(b, jsonEncode(k1AndK2),
          ttl: 86400000,
          appMetadata:
              AppMetadata(providerId: 'acme', additional: {'other': 'kept'}));
      final AtData before = await record(b);
      expect(before.metaData!.expiresAt, isNotNull,
          reason: 'precondition: the record expires');
      await Future.delayed(Duration(milliseconds: 5));
      await link(etu.primaryEnId, b, {k1: wellFormedK1});
      final AtData after = await record(b);
      expect(after.data, before.data);
      expect(after.metaData!.appMetadata!.providerId, 'acme');
      expect(after.metaData!.appMetadata!.additional!['other'], 'kept');
      expect(after.metaData!.expiresAt, before.metaData!.expiresAt);
      expect(await linksOn(b), {k1: wellFormedK1['link']});
    });
  });

  group('a link replaces only the link its writer found', () {
    late String b;
    late Map<String, dynamic> l1;

    setUp(() async {
      b = await enrollment('b', apsk: k1AndK2);
      l1 = chainLink(payload(b, k1, 'mldsa65', p1), signature: 'L1');
      await link(etu.primaryEnId, b, {
        k1: {'link': l1, 'expect': null}
      });
    });

    Map<String, dynamic> l2() =>
        rootLink(payload(b, k1, 'mldsa65', p1), signature: 'L2');

    test('a copy of "none" is refused, and L1 stays on K1', () async {
      await expectLater(
          link(etu.primaryEnId, b, {
            k1: {'link': l2(), 'expect': null}
          }),
          refusedNaming<IllegalStateException>(k1));
      expect(await linksOn(b), {k1: l1});
    });

    test('a copy of a link other than L1 is refused, and L1 stays on K1',
        () async {
      final Map<String, dynamic> other =
          chainLink(payload(b, k1, 'mldsa65', p1), signature: 'L3');
      await expectLater(
          link(etu.primaryEnId, b, {
            k1: {'link': l2(), 'expect': other}
          }),
          refusedNaming<IllegalStateException>(k1));
      expect(await linksOn(b), {k1: l1});
    });

    test('a copy of L1, compared as JSON, lets the new link replace it',
        () async {
      final Map<String, dynamic> reordered = {
        for (final String field in l1.keys.toList().reversed) field: l1[field]
      };
      expect(jsonEncode(reordered), isNot(jsonEncode(l1)),
          reason: 'precondition: the copy differs from L1 as a string');
      final Map<String, dynamic> replacement = l2();
      await link(etu.primaryEnId, b, {
        k1: {'link': replacement, 'expect': reordered}
      });
      expect(await linksOn(b), {k1: replacement});
    });

    test(
        'of two vouchers each sending the copy "none", the first is written '
        'and the second refused', () async {
      final Map<String, dynamic> first =
          chainLink(payload(b, k2, 'rsa2048', p2), signature: 'first');
      final Map<String, dynamic> second =
          rootLink(payload(b, k2, 'rsa2048', p2), signature: 'second');
      Future<Object?> attempt(Map<String, dynamic> l) =>
          link(etu.primaryEnId, b, {
            k2: {'link': l, 'expect': null}
          }).then<Object?>((_) => l, onError: (Object e) => e);
      final List<Object?> outcomes =
          await Future.wait([attempt(first), attempt(second)]);
      expect(outcomes[0], first);
      expect(outcomes[1], isA<IllegalStateException>());
      expect(await linksOn(b), {k1: l1, k2: first});
    });
  });

  group('any other write of B\'s _apsk keeps B\'s links', () {
    late String b;
    late Map<String, dynamic> l1;
    late Map<String, dynamic> l2;

    setUp(() async {
      b = await enrollment('b', apsk: k1AndK2);
      l1 = chainLink(payload(b, k1, 'mldsa65', p1));
      l2 = rootLink(payload(b, k2, 'rsa2048', p2));
      await link(etu.primaryEnId, b, {
        k1: {'link': l1, 'expect': null},
        k2: {'link': l2, 'expect': null}
      });
    });

    final Map<String, dynamic> k1K2AndK3 = listForm([
      entry(k1, 'mldsa65', p1),
      entry(k2, 'rsa2048', p2),
      entry(k3, 'mldsa65', p3)
    ]);
    final Map<String, dynamic> k1Only = listForm([entry(k1, 'mldsa65', p1)]);

    /// What an older client sends on a put: the version 1 link fields, and
    /// a link map of its own.
    AppMetadata olderClientAppMetadata() =>
        AppMetadata(providerId: 'legacy', additional: {
          'apskChainLink': {'v': 1, 'payload': 'old'},
          'apskRootLink': {'v': 1, 'payload': 'old'},
          'apskLinks': {
            k1: {'payload': 'sent by the put'}
          },
        });

    test(
        'an enroll:update republish that adds K3 keeps the links for K1 and K2',
        () async {
      await republish(b, k1K2AndK3);
      expect((await record(b)).data, jsonEncode(k1K2AndK3));
      expect(await linksOn(b), {k1: l1, k2: l2});
    });

    test('a put of the record keeps them, whatever it sends', () async {
      await put(b, jsonEncode(k1K2AndK3),
          appMetadata: olderClientAppMetadata());
      expect((await record(b)).data, jsonEncode(k1K2AndK3));
      expect(await linksOn(b), {k1: l1, k2: l2});
      expect(
          (await record(b)).metaData!.appMetadata!.additional!['apskChainLink'],
          {'v': 1, 'payload': 'old'},
          reason: 'the put\'s other appMetadata fields are stored as sent');
    });

    test('a put sending no appMetadata keeps them', () async {
      await put(b, jsonEncode(k1K2AndK3));
      expect(await linksOn(b), {k1: l1, k2: l2});
    });

    test('an update:meta keeps them, whatever it sends', () async {
      connectAs(b);
      final r = Response();
      await UpdateMetaVerbHandler(keyValueStore, statsNotificationService,
              notificationManager, alice)
          .processVerb(
              r,
              getVerbParam(
                  VerbSyntax.update_meta,
                  'update:meta:${apskKey(b)}:appMetadata:'
                  '${Metadata.encodeAppMetadata(olderClientAppMetadata())}'),
              inboundConnection);
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await linksOn(b), {k1: l1, k2: l2});
    });

    test(
        'an enroll:update republish that no longer lists K2 removes K2\'s '
        'link in the same write', () async {
      await republish(b, k1Only);
      expect(await linksOn(b), {k1: l1});
    });

    test('a put that no longer lists K2 removes K2\'s link in the same write',
        () async {
      await put(b, jsonEncode(k1Only), appMetadata: olderClientAppMetadata());
      expect(await linksOn(b), {k1: l1});
    });

    test('an enroll:update republish keeps the record\'s other appMetadata',
        () async {
      await put(b, jsonEncode(k1AndK2),
          appMetadata:
              AppMetadata(providerId: 'acme', additional: {'other': 'kept'}));
      await republish(b, k1K2AndK3);
      final AppMetadata stored = (await record(b)).metaData!.appMetadata!;
      expect(stored.providerId, 'acme');
      expect(stored.additional!['other'], 'kept');
      expect(await linksOn(b), {k1: l1, k2: l2});
    });

    test(
        'a write that leaves no listed key with a link stores no link map, '
        'not even an empty one', () async {
      final Map<String, dynamic> k3Only = listForm([entry(k3, 'mldsa65', p3)]);
      await put(b, jsonEncode(k3Only),
          appMetadata:
              AppMetadata(providerId: 'acme', additional: {'other': 'kept'}));
      expect((await record(b)).metaData!.appMetadata!.additional,
          {'other': 'kept'});
      await put(b, jsonEncode(k1AndK2));
      await link(etu.primaryEnId, b, {
        k1: {'link': l1, 'expect': null}
      });
      await put(b, jsonEncode(k3Only),
          appMetadata: AppMetadata(providerId: 'acme'));
      expect((await record(b)).metaData!.appMetadata!.additional, isNull);
    });

    test(
        'a put of an _apsk record with no links, sending no appMetadata, '
        'stores none', () async {
      final String c = await enrollment('c', apsk: k1AndK2);
      expect((await record(c)).metaData?.appMetadata, isNull,
          reason: 'precondition: the published record carries none');
      await put(c, jsonEncode(k1K2AndK3));
      expect((await record(c)).data, jsonEncode(k1K2AndK3));
      expect((await record(c)).metaData?.appMetadata, isNull);
    });

    test('a put of any other key stores the appMetadata it sends', () async {
      const String other = 'public:other.buzz';
      final AppMetadata sent = olderClientAppMetadata();
      connectAs(null);
      final r = Response();
      await etu.uvh.processVerb(
          r,
          getVerbParam(
              VerbSyntax.update,
              'update:appMetadata:${Metadata.encodeAppMetadata(sent)}:'
              '$other$alice ${jsonEncode(k1Only)}'),
          inboundConnection);
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(
          (await keyValueStore.get('$other$alice'))!
              .metaData!
              .appMetadata!
              .additional,
          sent.additional);
    });

    test('only an approved enrollment\'s own _apsk key is taken for one', () {
      expect(ApskLinks.enrollmentIdOf(apskKey(b), alice), b);
      expect(ApskLinks.enrollmentIdOf(apskKey(b).toUpperCase(), alice), b);
      for (final String other in [
        'public:_apsk.$b.d.__e$alice',
        'public:_apsx.$b.a.__e$alice',
        'public:_apsk.x.$b.a.__e$alice',
        'public:_apsk.$b.a.__e@bob',
      ]) {
        expect(ApskLinks.enrollmentIdOf(other, alice), isNull, reason: other);
      }
    });

    DeleteVerbHandler deleteHandler() => DeleteVerbHandler(
        keyValueStore, statsNotificationService, notificationManager);

    test(
        'a delete of B\'s _apsk waits for an enrollment write in progress, '
        'and then removes it', () async {
      final Completer<void> release = Completer<void>();
      final Future<void> held = enMgr.serialiseMutation(() => release.future);
      connectAs(b);
      final r = Response();
      final DeleteVerbHandler handler = deleteHandler();
      final Future<void> deleting = handler.processVerb(
          r, handler.parse('delete:${apskKey(b)}'), inboundConnection);
      await Future.delayed(Duration(milliseconds: 50));
      expect(await keyValueStore.exists(apskKey(b)), true,
          reason: 'the delete has not removed it while the lock is held');
      release.complete();
      await held;
      await deleting;
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await keyValueStore.exists(apskKey(b)), false);
    });

    test('a delete of any other key does not wait for an enrollment write',
        () async {
      const String other = 'public:other.buzz';
      await keyValueStore.put('$other$alice', AtData()..data = 'value');
      final Completer<void> release = Completer<void>();
      final Future<void> held = enMgr.serialiseMutation(() => release.future);
      connectAs(null);
      final DeleteVerbHandler handler = deleteHandler();
      try {
        await handler
            .processVerb(Response(), handler.parse('delete:$other$alice'),
                inboundConnection)
            .timeout(Duration(seconds: 5));
        expect(await keyValueStore.exists('$other$alice'), false);
      } finally {
        release.complete();
        await held;
      }
    });

    test(
        'a keys:delete of B\'s _apsk waits for an enrollment write in '
        'progress, and then removes it', () async {
      await put(b, jsonEncode({...k1AndK2, 'enrollmentId': b}));
      final Completer<void> release = Completer<void>();
      final Future<void> held = enMgr.serialiseMutation(() => release.future);
      connectAs(b);
      final Future<void> deleting = KeysVerbHandler(keyValueStore, enMgr, alice)
          .process('keys:delete:keyName:${apskKey(b)}', inboundConnection);
      await Future.delayed(Duration(milliseconds: 50));
      expect(await keyValueStore.exists(apskKey(b)), true,
          reason: 'the keys:delete has not removed it while the lock is held');
      release.complete();
      await held;
      await deleting;
      expect(await keyValueStore.exists(apskKey(b)), false);
    });

    /// Sends an `enroll:link` for K1 and [removeK1] while an enrollment write
    /// is in progress, then lets them run.
    Future<void> together(Future<void> Function() removeK1) async {
      final Map<String, dynamic> relinked =
          rootLink(payload(b, k1, 'mldsa65', p1), signature: 'relinked');
      final Completer<void> release = Completer<void>();
      final Future<void> held = enMgr.serialiseMutation(() => release.future);
      final Future<List<Object?>> outcomes = Future.wait([
        link(b, b, {
          k1: {'link': relinked, 'expect': l1}
        }).then<Object?>((r) => r, onError: (Object e) => e),
        removeK1().then<Object?>((_) => null, onError: (Object e) => e),
      ]);
      await Future.delayed(Duration(milliseconds: 50));
      expect((await record(b)).data, jsonEncode(k1AndK2),
          reason: 'neither writes while an enrollment write is in progress');
      expect(await linksOn(b), {k1: l1, k2: l2},
          reason: 'neither writes while an enrollment write is in progress');
      release.complete();
      await held;
      expect((await outcomes)[1], isNull, reason: 'the republish succeeds');
      expect(await linksOn(b), {k2: l2});
    }

    final Map<String, dynamic> k2Only = listForm([entry(k2, 'rsa2048', p2)]);

    test(
        'a put of B\'s _apsk waits for an enrollment write in progress, and '
        'keeps the links it leaves', () async {
      final Completer<void> release = Completer<void>();
      final Future<void> held = enMgr.serialiseMutation(() => release.future);
      final Future<void> putting = put(b, jsonEncode(k1K2AndK3));
      await Future.delayed(Duration(milliseconds: 50));
      expect((await record(b)).data, jsonEncode(k1AndK2),
          reason: 'the put has not written while the lock is held');
      release.complete();
      await held;
      await putting;
      expect((await record(b)).data, jsonEncode(k1K2AndK3));
      expect(await linksOn(b), {k1: l1, k2: l2});
    });

    test(
        'an enroll:link for K1 and an enroll:update republish that removes K1, '
        'arriving together, leave K1 with no link and lose no other', () async {
      await together(() => republish(b, k2Only));
    });

    test(
        'an enroll:link for K1 and a put that removes K1, arriving together, '
        'leave K1 with no link and lose no other', () async {
      await together(() => put(b, jsonEncode(k2Only)));
    });
  });

  group('an enrollment\'s authentication key takes no links', () {
    test(
        'a bare _apsk that is the enrollment\'s apkamPublicKey is refused a '
        'link, and nothing is written', () async {
      final b = await enrollment('b', apkamPublicKey: p1, apskLegacy: p1);
      await expectLater(
          link(etu.primaryEnId, b, {
            k1: {
              'link': chainLink(payload(b, k1, 'rsa2048', p1)),
              'expect': null
            }
          }),
          refusedNaming<IllegalArgumentException>(k1));
      expect(await linksOn(b), isNull);
    });

    test(
        'an authentication key listed alone in the list form is refused a '
        'link, and nothing is written', () async {
      final b = await enrollment('b',
          apkamPublicKey: p1,
          signingAlgo: 'mldsa65',
          apsk: listForm([entry(k1, 'mldsa65', p1)]));
      await expectLater(
          link(etu.primaryEnId, b, {
            k1: {
              'link': chainLink(payload(b, k1, 'mldsa65', p1)),
              'expect': null
            }
          }),
          refusedNaming<IllegalArgumentException>(k1));
      expect(await linksOn(b), isNull);
    });

    for (final (String form, String apkamPublicKey) in [
      ('in the URL-safe alphabet', '-_8='),
      ('with a trailing newline', '$pFbff\n'),
      ('with a leading space', ' $pFbff'),
    ]) {
      test(
          'an authentication key its record holds spelt $form, listed in '
          'padded standard base64, is refused a link, and nothing is written',
          () async {
        final b = await enrollment('b',
            apkamPublicKey: apkamPublicKey,
            signingAlgo: 'mldsa65',
            apsk: listForm([entry(kFbff, 'mldsa65', pFbff)]));
        await expectLater(
            link(etu.primaryEnId, b, {
              kFbff: {
                'link': chainLink(payload(b, kFbff, 'mldsa65', pFbff)),
                'expect': null
              }
            }),
            refusedNaming<IllegalArgumentException>(
                'advertises no key $kFbff that can take a link'));
        expect(await linksOn(b), isNull);
      });
    }

    test(
        'a bare _apsk that is the authentication key its record holds in the '
        'URL-safe alphabet is refused a link, and nothing is written',
        () async {
      final b =
          await enrollment('b', apkamPublicKey: '-_8=', apskLegacy: pFbff);
      await expectLater(
          link(etu.primaryEnId, b, {
            kFbff: {
              'link': chainLink(payload(b, kFbff, 'rsa2048', pFbff)),
              'expect': null
            }
          }),
          refusedNaming<IllegalArgumentException>(
              'advertises no key $kFbff that can take a link'));
      expect(await linksOn(b), isNull);
    });
  });

  group('a bare RSA signing key is linked like a listed one', () {
    late String b;
    late Map<String, dynamic> bareLink;

    setUp(() async {
      b = await enrollment('b',
          apkamPublicKey: 'ml-dsa-65 authentication key',
          signingAlgo: 'mldsa65',
          apskLegacy: p1);
      bareLink = rootLink(payload(b, k1, 'rsa2048', p1));
    });

    test(
        'the bare value is one rsa2048 entry whose kid is derived from the '
        'key, and the link is written', () async {
      expect(
          await link(etu.primaryEnId, b, {
            k1: {'link': bareLink, 'expect': null}
          }),
          {
            'enrollmentId': b,
            'linked': [k1]
          });
      expect(await linksOn(b), {k1: bareLink});
    });

    test(
        'listed in the list form beside an ML-DSA-65 key and retired, the RSA '
        'key keeps the same kid and keeps its link', () async {
      await link(etu.primaryEnId, b, {
        k1: {'link': bareLink, 'expect': null}
      });
      await republish(
          b,
          listForm([
            entry(k2, 'mldsa65', p2),
            entry(k1, 'rsa2048', p1, status: 'retired')
          ]));
      expect(await linksOn(b), {k1: bareLink});
    });
  });

  test('an enroll operation the atServer does not support is refused',
      () async {
    connectAs(null);
    final int before = await (await keyValueStore.getKeys()).length;
    await expectLater(
        etu.evh.processVerb(
            Response(),
            HashMap<String, String?>.from({
              'operation': 'sign',
              AtConstants.enrollParams:
                  jsonEncode({'enrollmentId': etu.primaryEnId}),
            }),
            inboundConnection),
        refusedNaming<InvalidSyntaxException>('enroll:sign'));
    expect(await (await keyValueStore.getKeys()).length, before);
  });
}
