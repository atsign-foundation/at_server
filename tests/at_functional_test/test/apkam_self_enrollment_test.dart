import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional coverage of the APKAM self-enrollment branch (RF-SRV): an
/// `enroll:request` arriving on an APKAM-authenticated connection resolves
/// that connection's enrollment as the PARENT and auto-approves a child that
/// can hold at most what the parent holds.
///
/// The unit suite in `at_secondary_server` pins the handler's decisions
/// directly. These tests drive the same decisions over the wire, which is the
/// only place the surrounding machinery — the enrollment record's ttl, the
/// published `_apsk`, and whether the child can actually PKAM-authenticate —
/// is observable.
void main() {
  String atSign = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String host = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int port = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String apkamPublicKey = apkamPublicKeyMap[atSign]!;
  String encryptedPrivateKey = EncryptionUtil.encryptValue(
      encryptionPrivateKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedSelfKey = EncryptionUtil.encryptValue(
      aesKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedApkamSymmetricKey = EncryptionUtil.encryptKey(
      apkamSymmetricKeyMap[atSign]!, encryptionPublicKeyMap[atSign]!);

  /// Connections opened by a test, closed in tearDown.
  List<OutboundConnectionFactory> open = [];

  Future<OutboundConnectionFactory> newConnection() async {
    OutboundConnectionFactory c = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    open.add(c);
    return c;
  }

  /// A CRAM-authenticated connection: the atSign's own, used to issue OTPs,
  /// approve enrollments and read enrollment records back.
  Future<OutboundConnectionFactory> ownerConnection() async {
    OutboundConnectionFactory c = await newConnection();
    expect((await c.authenticateConnection(authType: AuthType.cram)).trim(),
        'data:success');
    return c;
  }

  /// Creates an APPROVED enrollment holding exactly [namespaces] via the
  /// ordinary OTP flow, and returns its enrollment id. This is the parent a
  /// self-enrollment runs under.
  ///
  /// [appName] and [deviceName] default to run-unique values: an approved
  /// (appName, deviceName) pair may not be re-used by the ordinary path, so
  /// fixed names would pass once and collide on the next run.
  Future<String> createApprovedEnrollment(OutboundConnectionFactory owner,
      {required Map<String, String> namespaces,
      String? appName,
      String? deviceName,
      int? apkamKeysExpiryInMillis}) async {
    String otp = (await owner.sendRequestToServer('otp:get'))
        .replaceFirst('data:', '')
        .trim();
    appName ??= 'app-${Uuid().v4().hashCode}';
    deviceName ??= 'device-${Uuid().v4().hashCode}';
    String expiry = apkamKeysExpiryInMillis == null
        ? ''
        : ',"apkamKeysExpiryInMillis":$apkamKeysExpiryInMillis';
    // One enroll:request per connection: the rate limiter is per-connection,
    // and another test file lowers maxRequestsPerTimeFrame server-wide.
    OutboundConnectionFactory requester = await newConnection();
    String response = await requester.sendRequestToServer(
        'enroll:request:{"appName":"$appName","deviceName":"$deviceName","namespaces":${jsonEncode(namespaces)},"otp":"$otp","apkamPublicKey":"$apkamPublicKey","encryptedAPKAMSymmetricKey":"$encryptedApkamSymmetricKey"$expiry}');
    String enrollmentId =
        jsonDecode(response.replaceFirst('data:', ''))['enrollmentId'];
    String approval = await owner.sendRequestToServer(
        'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"$encryptedPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfKey"}');
    expect(jsonDecode(approval.replaceFirst('data:', ''))['status'], 'approved');
    return enrollmentId;
  }

  /// Sends one `enroll:request` on a connection APKAM-authenticated as
  /// [parentId], and returns the raw server response.
  Future<String> selfEnroll(String parentId,
      {required Map<String, String> namespaces,
      String? appName,
      String? deviceName,
      int? apkamKeysExpiryInMillis,
      String? signingAlgo,
      Map<String, dynamic>? apsk}) async {
    OutboundConnectionFactory parent = await newConnection();
    expect(
        (await parent.authenticateConnection(
                authType: AuthType.apkam, enrollmentId: parentId))
            .trim(),
        'data:success',
        reason: 'the parent must be able to authenticate before it self-enrols');
    String expiry = apkamKeysExpiryInMillis == null
        ? ''
        : ',"apkamKeysExpiryInMillis":$apkamKeysExpiryInMillis';
    String algo = signingAlgo == null ? '' : ',"signingAlgo":"$signingAlgo"';
    String apskField = apsk == null ? '' : ',"apsk":${jsonEncode(apsk)}';
    return (await parent.sendRequestToServer(
            'enroll:request:{"appName":"${appName ?? 'child-${Uuid().v4().hashCode}'}","deviceName":"${deviceName ?? 'device-${Uuid().v4().hashCode}'}","namespaces":${jsonEncode(namespaces)},"apkamPublicKey":"$apkamPublicKey"$expiry$algo$apskField}'))
        .trim();
  }

  /// [selfEnroll] for the cases that are expected to succeed.
  Future<String> selfEnrollId(String parentId,
      {required Map<String, String> namespaces,
      String? appName,
      String? deviceName,
      int? apkamKeysExpiryInMillis,
      String? signingAlgo,
      Map<String, dynamic>? apsk}) async {
    String response = await selfEnroll(parentId,
        namespaces: namespaces,
        appName: appName,
        deviceName: deviceName,
        apkamKeysExpiryInMillis: apkamKeysExpiryInMillis,
        signingAlgo: signingAlgo,
        apsk: apsk);
    Map decoded = jsonDecode(response.replaceFirst('data:', ''));
    expect(decoded['status'], 'approved',
        reason: 'a self-enrollment is auto-approved with no human step');
    expect(decoded['enrollmentId'], isNotEmpty);
    return decoded['enrollmentId'];
  }

  /// The enrollment record as stored, including its metadata — the only place
  /// the written ttl and the recorded parent are observable.
  Future<({Map<String, dynamic> value, Map<String, dynamic> metaData})>
      enrollmentRecord(OutboundConnectionFactory owner, String id) async {
    String response = (await owner.sendRequestToServer(
            'llookup:all:$id.new.enrollments.__manage$atSign'))
        .trim()
        .replaceFirst('data:', '');
    Map decoded = jsonDecode(response);
    return (
      value: jsonDecode(decoded['data']) as Map<String, dynamic>,
      metaData: decoded['metaData'] as Map<String, dynamic>,
    );
  }

  tearDown(() async {
    for (final c in open) {
      await c.close();
    }
    open = [];
  });

  group('A self-enrollment is auto-approved and usable', () {
    test('an approved parent self-enrolls a subset child that can authenticate',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String childId =
          await selfEnrollId(parentId, namespaces: {'wavi': 'r'});

      // The child is not merely recorded: it authenticates.
      OutboundConnectionFactory child = await newConnection();
      expect(
          (await child.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: childId))
              .trim(),
          'data:success');
    });

    test('the child records its parent, so a revoke can cascade later',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId, namespaces: {'wavi': 'r'});

      final child = await enrollmentRecord(owner, childId);
      expect(child.value['parentEnrollmentId'], parentId);
      expect(child.value['namespaces'], {'wavi': 'r'});
      expect(child.value['approval']['state'], 'approved');
    });

    test('a self-enrolled child needs no encrypted APKAM symmetric key',
        () async {
      // A PQ self-enrollment conveys its legacy material client-side, sealed
      // to its own new key package, so the field the ordinary path demands is
      // absent here.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId, namespaces: {'wavi': 'r'});

      final child = await enrollmentRecord(owner, childId);
      expect(child.value['encryptedAPKAMSymmetricKey'], isNull);
    });

    test(
        'a retrofit keeps its own (appName, deviceName) where the ordinary path may not',
        () async {
      // Uniqueness of (appName, deviceName) among live enrollments ends on
      // this branch by design: a retrofit is the same app re-enrolling itself,
      // and sibling clones of one keyfile share those names.
      OutboundConnectionFactory owner = await ownerConnection();
      String appName = 'retrofit-${Uuid().v4().hashCode}';
      String deviceName = 'device-${Uuid().v4().hashCode}';
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'},
          appName: appName,
          deviceName: deviceName);

      // Same names, twice, on the self-enrollment branch: both approved.
      await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'},
          appName: appName,
          deviceName: deviceName);
      await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'},
          appName: appName,
          deviceName: deviceName);

      // Control: the ORDINARY path still refuses those same names, so the
      // assertions above record a difference between the two branches rather
      // than a duplicate check that never fires.
      String otp = (await owner.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '')
          .trim();
      OutboundConnectionFactory ordinary = await newConnection();
      String response = await ordinary.sendRequestToServer(
          'enroll:request:{"appName":"$appName","deviceName":"$deviceName","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"$apkamPublicKey","encryptedAPKAMSymmetricKey":"$encryptedApkamSymmetricKey"}');
      expect(response.trim(), startsWith('error:'),
          reason: 'the ordinary path must still reject duplicate names');
    });
  });

  group('A self-enrollment may not escalate beyond its parent', () {
    test('a namespace the parent does not hold is refused', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String response =
          await selfEnroll(parentId, namespaces: {'buzz': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(
          error['errorDescription'],
          contains('Requested namespace "buzz:rw" exceeds the parent '
              'enrollment\'s grants'));
    });

    test('broader access letters on a held namespace are refused', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'atmosphere': 'r'});

      String response =
          await selfEnroll(parentId, namespaces: {'atmosphere': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(error['errorDescription'],
          contains('Requested namespace "atmosphere:rw" exceeds'));
    });

    test('a wildcard parent cannot mint __manage', () async {
      // `*` does not imply `__manage` anywhere else in the server, and it must
      // not here — otherwise any `*` keyfile could self-spawn an enrollment
      // that administers every other enrollment.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'*': 'rw'});

      String response =
          await selfEnroll(parentId, namespaces: {'__manage': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(error['errorDescription'],
          contains('Requested namespace "__manage:rw" exceeds'));
    });

    test('a wildcard parent does cover an ordinary namespace it never named',
        () async {
      // The positive half of the rule above: without this, the refusal test
      // would pass just as well against a branch that refused everything.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'*': 'rw'});

      String childId = await selfEnrollId(parentId,
          namespaces: {'a-namespace-never-named': 'rw'});
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['namespaces'], {'a-namespace-never-named': 'rw'});
    });

    test('an empty namespace set is refused', () async {
      // An approved credential that can do nothing is always a caller bug.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String response = await selfEnroll(parentId, namespaces: {});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0022');
      expect(
          error['errorDescription'],
          contains('At least one namespace must be specified for an '
              'APKAM-authenticated enroll:request'));
    });
  });

  group('A self-enrolled child expires, and may not outlive its parent', () {
    // One hour, so a child asking for longer, for "never", or for a negative
    // value has something to be clamped against.
    const int oneHourMs = 3600000;

    test('a child inherits the parent\'s key-expiry posture', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String childId = await selfEnrollId(parentId, namespaces: {'wavi': 'r'});
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['apkamKeysExpiryInMillis'], oneHourMs);
      // The posture is not merely recorded, it is written as the record's ttl
      // — the hole that made an inherited expiry into immortality.
      expect(child.metaData['ttl'], oneHourMs);
      expect(child.metaData['expiresAt'], isNotNull);
    });

    test('a child may state a SHORTER expiry than its parent', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String childId = await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'}, apkamKeysExpiryInMillis: 60000);
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['apkamKeysExpiryInMillis'], 60000);
      expect(child.metaData['ttl'], 60000);
    });

    test('a child may not state an expiry that outlives its parent', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String childId = await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'}, apkamKeysExpiryInMillis: 999999999);
      final child = await enrollmentRecord(owner, childId);
      // Clamped to the parent's, not refused: a client asking for longer
      // without knowing is corrected rather than broken.
      expect(child.value['apkamKeysExpiryInMillis'], oneHourMs);
      expect(child.metaData['ttl'], oneHourMs);
    });

    test('a child may not state "never expires" against a bounded parent',
        () async {
      // Zero is the keystore's "never expires" — the route by which a stolen,
      // hour-bound keyfile would mint itself a permanent credential.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String childId = await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'}, apkamKeysExpiryInMillis: 0);
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['apkamKeysExpiryInMillis'], oneHourMs);
      expect(child.metaData['ttl'], oneHourMs);
    });

    test('a negative stated expiry is not honoured', () async {
      // A negative value skips the ttl write altogether, so it is the same
      // ask as "never expires" by a different route.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String childId = await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'}, apkamKeysExpiryInMillis: -1);
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['apkamKeysExpiryInMillis'], oneHourMs);
      expect(child.metaData['ttl'], oneHourMs);
    });
  });

  group('The parent survives a retrofit, capped rather than removed', () {
    test('the parent still authenticates after a child self-enrolls',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      await selfEnrollId(parentId, namespaces: {'wavi': 'r'});

      OutboundConnectionFactory parent = await newConnection();
      expect(
          (await parent.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: parentId))
              .trim(),
          'data:success',
          reason: 'sibling clones must still be able to retrofit');
    });

    test('the cap re-arms on each sibling retrofit', () async {
      // A deadline fixed by the first sibling's upgrade would strand every
      // laggard whose next run fell outside that window.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      await selfEnrollId(parentId, namespaces: {'wavi': 'r'});
      final afterFirst = await enrollmentRecord(owner, parentId);
      DateTime firstCap = DateTime.parse(afterFirst.metaData['expiresAt']);

      await Future.delayed(Duration(seconds: 2));

      await selfEnrollId(parentId, namespaces: {'wavi': 'r'});
      final afterSecond = await enrollmentRecord(owner, parentId);
      DateTime secondCap = DateTime.parse(afterSecond.metaData['expiresAt']);

      expect(secondCap.isAfter(firstCap), isTrue,
          reason: 'the second retrofit must push the parent\'s expiry out, '
              'not leave the first retrofit\'s deadline in place');
    });
  });

  group('A key-package request may omit the RSA-wrapped symmetric key', () {
    test('a request advertising a key package is accepted without one',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String otp = (await owner.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '')
          .trim();

      OutboundConnectionFactory requester = await newConnection();
      String response = await requester.sendRequestToServer(
          'enroll:request:{"appName":"kp-${Uuid().v4().hashCode}","deviceName":"device-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"$apkamPublicKey","metadata":{"keyPackage":"a-key-package"}}');
      Map decoded = jsonDecode(response.replaceFirst('data:', ''));
      expect(decoded['status'], 'pending');
      expect(decoded['enrollmentId'], isNotEmpty);
    });

    test('without a key package the symmetric key is still mandatory',
        () async {
      // The control: a client that sends neither has no route to a symmetric
      // key at all, and failing here beats enrolling into a state it cannot
      // decrypt.
      OutboundConnectionFactory owner = await ownerConnection();
      String otp = (await owner.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '')
          .trim();

      OutboundConnectionFactory requester = await newConnection();
      String response = await requester.sendRequestToServer(
          'enroll:request:{"appName":"kp-${Uuid().v4().hashCode}","deviceName":"device-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"$apkamPublicKey"}');
      expect(
          response.trim(),
          contains(
              'encrypted apkam symmetric key is mandatory for new client enroll:request'));
    });
  });

  group('The published _apsk is whatever the client composed', () {
    Future<String> apskValue(
        OutboundConnectionFactory owner, String enrollmentId) async {
      return (await owner
              .sendRequestToServer('llookup:public:_apsk.$enrollmentId.a.__e$atSign'))
          .trim()
          .replaceFirst('data:', '');
    }

    test('the value sent on enroll:request is published verbatim', () async {
      // A shape with a field the atServer has no code for, on purpose: the
      // value is opaque, so what a verifier resolves must be what the enrollee
      // composed and nothing the server could have derived from the record.
      Map<String, dynamic> composed = {
        'v': 1,
        'signingAlgo': 'mldsa65',
        'publicKey': 'Y2xpZW50LWNvbXBvc2VkLWtleQ==',
        'extraFieldTheServerMustNotDrop': ['a', 'b'],
      };

      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'}, signingAlgo: 'mldsa65', apsk: composed);

      expect(jsonDecode(await apskValue(owner, childId)), composed);
    });

    test('an enrollment that sends no apsk gets no _apsk record', () async {
      // The atServer composes nothing from (apkamPublicKey, signingAlgo):
      // PKAM verification reads the enrollment record, so this key is the
      // enrollee's to publish from its own connection, or to go without.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId,
          namespaces: {'wavi': 'r'}, signingAlgo: 'mldsa65');

      expect(
          await apskValue(owner, childId),
          contains('key not found : public:_apsk.$childId.a.__e$atSign '
              'does not exist in keystore'));
    });
  });

  group('PKAM trusts the enrollment record over the wire claim', () {
    test('an enrollment with no recorded signingAlgo stays rsa2048 even when '
        'the wire claims mldsa65', () async {
      // The record is authoritative for an APKAM connection. If the claim
      // picked the verify routine, this legitimate RSA enrollment would be
      // verified as ML-DSA and fail.
      OutboundConnectionFactory owner = await ownerConnection();
      String enrollmentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      final record = await enrollmentRecord(owner, enrollmentId);
      expect(record.value['signingAlgo'], isNull,
          reason: 'the enrollment under test must have no recorded algorithm');

      OutboundConnectionFactory client = await newConnection();
      String challenge = (await client.sendRequestToServer(
              'from:$atSign:clientConfig:${jsonEncode({'version': '3.0.57'})}'))
          .replaceAll('data:', '');
      String signature = AuthenticationUtils.generatePKAMDigest(
          apkamPrivateKeyMap[atSign]!, challenge);

      expect(
          (await client.sendRequestToServer(
                  'pkam:signingAlgo:mldsa65:enrollmentId:$enrollmentId:$signature'))
              .trim(),
          'data:success');
    });
  });
}
