import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional coverage of the APKAM self-enrollment branch: an
/// `enroll:request` arriving on an APKAM-authenticated connection auto-
/// approves a successor that REPLACES that connection's enrollment, carrying
/// exactly the grants its predecessor held — no more, and no less.
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
  /// [namespaces] is optional, mirroring the wire: a retrofit that omits
  /// it inherits its predecessor's grants, and one that states them must
  /// state exactly them.
  Future<String> selfEnroll(String parentId,
      {Map<String, String>? namespaces,
      String? appName,
      String? deviceName,
      int? apkamKeysExpiryInMillis,
      String? signingAlgo,
      Map<String, dynamic>? apsk,
      String? apskLegacy}) async {
    OutboundConnectionFactory parent = await newConnection();
    expect(
        (await parent.authenticateConnection(
                authType: AuthType.apkam, enrollmentId: parentId))
            .trim(),
        'data:success',
        reason: 'the parent must be able to authenticate before it self-enrols');
    String nsField =
        namespaces == null ? '' : ',"namespaces":${jsonEncode(namespaces)}';
    String expiry = apkamKeysExpiryInMillis == null
        ? ''
        : ',"apkamKeysExpiryInMillis":$apkamKeysExpiryInMillis';
    String algo = signingAlgo == null ? '' : ',"signingAlgo":"$signingAlgo"';
    String apskField = apsk == null ? '' : ',"apsk":${jsonEncode(apsk)}';
    // JSON-encoded HERE because this is the request envelope, which is JSON.
    // What the server must not do is encode it again when it publishes the
    // value; the tests below assert exactly that.
    String apskLegacyField =
        apskLegacy == null ? '' : ',"apskLegacy":${jsonEncode(apskLegacy)}';
    return (await parent.sendRequestToServer(
            'enroll:request:{"appName":"${appName ?? 'child-${Uuid().v4().hashCode}'}","deviceName":"${deviceName ?? 'device-${Uuid().v4().hashCode}'}","apkamPublicKey":"$apkamPublicKey"$nsField$expiry$algo$apskField$apskLegacyField}'))
        .trim();
  }

  /// Opens a fresh connection and authenticates it as [enrollmentId], which
  /// is what arms a retrofit's cap on the enrollment it replaced.
  Future<void> authenticateAsEnrollment(String enrollmentId) async {
    OutboundConnectionFactory conn = await newConnection();
    expect(
        (await conn.authenticateConnection(
                authType: AuthType.apkam, enrollmentId: enrollmentId))
            .trim(),
        'data:success',
        reason: 'the successor must be able to authenticate, or the arming '
            'this drives never happens');
  }

  /// [selfEnroll] for the cases that are expected to succeed.
  /// [namespaces] is optional, mirroring the wire: a retrofit that omits
  /// it inherits its predecessor's grants, and one that states them must
  /// state exactly them.
  Future<String> selfEnrollId(String parentId,
      {Map<String, String>? namespaces,
      String? appName,
      String? deviceName,
      int? apkamKeysExpiryInMillis,
      String? signingAlgo,
      Map<String, dynamic>? apsk,
      String? apskLegacy}) async {
    String response = await selfEnroll(parentId,
        namespaces: namespaces,
        appName: appName,
        deviceName: deviceName,
        apkamKeysExpiryInMillis: apkamKeysExpiryInMillis,
        signingAlgo: signingAlgo,
        apsk: apsk,
        apskLegacy: apskLegacy);
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
    test('an approved predecessor is replaced by a successor that can authenticate',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String childId =
          await selfEnrollId(parentId);

      // The child is not merely recorded: it authenticates.
      OutboundConnectionFactory child = await newConnection();
      expect(
          (await child.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: childId))
              .trim(),
          'data:success');
    });

    test('the successor records what it replaced, which is what the cascade '
        'walks', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);

      final child = await enrollmentRecord(owner, childId);
      expect(child.value['parentEnrollmentId'], parentId);
      expect(child.value['namespaces'], {'wavi': 'rw'},
          reason: 'the successor carries its predecessor\'s grants, so it '
              'holds rw here and not the r an earlier contract let a '
              'caller ask for');
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
      String childId = await selfEnrollId(parentId);

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
          appName: appName,
          deviceName: deviceName);
      await selfEnrollId(parentId,
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
          contains('Requested namespace "buzz:rw" exceeds the predecessor '
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

    test('a request naming a subset of a wildcard parent is refused', () async {
      // A * parent used to cover any ordinary namespace at its letters, so
      // this succeeded and minted a successor that could not do what the
      // enrollment it replaced could.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'*': 'rw'});

      String response = await selfEnroll(parentId,
          namespaces: {'a-namespace-never-named': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(error['errorDescription'], contains('carries its grants'));
    });

    test('a wildcard parent is inherited verbatim when nothing is named',
        () async {
      // The positive half: the rule is equality, not a refusal of everything.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'*': 'rw'});

      String childId = await selfEnrollId(parentId);
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['namespaces'], {'*': 'rw'});
    });

    test('an empty namespace set inherits, rather than being refused',
        () async {
      // Stating nothing is how a request asks to inherit: a retrofit does not
      // choose its grants, so it need not name them.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String response = await selfEnroll(parentId, namespaces: {});
      expect(response, startsWith('data:'),
          reason: 'an empty map states nothing, and the successor takes its '
              'predecessor\'s grants: $response');
      final childId =
          jsonDecode(response.replaceFirst('data:', ''))['enrollmentId'];
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['namespaces'], {'wavi': 'rw'});
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

      String childId = await selfEnrollId(parentId);
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
          apkamKeysExpiryInMillis: 60000);
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['apkamKeysExpiryInMillis'], 60000);
      expect(child.metaData['ttl'], 60000);
    });

    test('a child may not state an expiry that outlives its parent', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String childId = await selfEnrollId(parentId,
          apkamKeysExpiryInMillis: 999999999);
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
          apkamKeysExpiryInMillis: 0);
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
          apkamKeysExpiryInMillis: -1);
      final child = await enrollmentRecord(owner, childId);
      expect(child.value['apkamKeysExpiryInMillis'], oneHourMs);
      expect(child.metaData['ttl'], oneHourMs);
    });
  });

  group('The predecessor survives a retrofit, capped rather than removed',
      () {
    test('a CAPPED predecessor still authenticates', () async {
      // The whole reason the predecessor is capped rather than removed: sibling
      // clones of one keyfile retrofit on their own schedules and must keep
      // authenticating until the cap elapses. The successor has to authenticate
      // first, or the predecessor is not capped and this asserts nothing — the
      // fixture already authenticates as the predecessor to send the request.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);
      await authenticateAsEnrollment(childId);

      expect((await enrollmentRecord(owner, parentId)).metaData['expiresAt'],
          isNotNull,
          reason: 'control: the predecessor really is capped, so the '
              'authentication below is a capped credential authenticating and '
              'not an uncapped one');

      OutboundConnectionFactory parent = await newConnection();
      expect(
          (await parent.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: parentId))
              .trim(),
          'data:success',
          reason: 'a capped credential keeps working until its deadline — a '
              'cap written as "already expired" would lock every laggard '
              'sibling out of the upgrade it still has to perform');
    });

    test('the successor records WHEN it armed, under a stable at-rest name',
        () async {
      // Raw-literal pin. Every other assertion reads this through the typed
      // getter, so writer and reader are the same hand-maintained pair in
      // enroll_datastore_value.g.dart: rename the JSON key symmetrically and
      // they all still pass, while every already-stored record silently loses
      // its stamp and re-arms once more.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);

      expect((await enrollmentRecord(owner, childId)).value,
          isNot(contains('predecessorCapArmedAt')),
          reason: 'absent until it arms, so an unarmed successor is '
              'distinguishable from an armed one at rest');

      await authenticateAsEnrollment(childId);

      final armed = (await enrollmentRecord(owner, childId)).value;
      expect(armed['predecessorCapArmedAt'], isA<String>(),
          reason: 'the at-rest key name and its ISO-8601 encoding are what a '
              'record written by an earlier server is read back through');
      expect(DateTime.parse(armed['predecessorCapArmedAt']).isUtc, isTrue);
    });

    test('revoking an enrollment does not restart its expiry either',
        () async {
      // The carry covers revoke, deny and unrevoke as well as update, and the
      // CHANGELOG says so. Without a test here, deleting the whole
      // `operation != 'approve'` block would leave the suite green.
      OutboundConnectionFactory owner = await ownerConnection();
      String id = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: 3600000);

      final DateTime before =
          DateTime.parse((await enrollmentRecord(owner, id)).metaData['expiresAt']);
      expect(before.isAfter(DateTime.now().toUtc()), isTrue,
          reason: 'precondition: it has a live deadline to move');

      await Future.delayed(Duration(seconds: 2));

      String response = await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$id"}');
      expect(response, startsWith('data:'), reason: response);

      expect(
          DateTime.parse(
              (await enrollmentRecord(owner, id)).metaData['expiresAt']),
          before,
          reason: 'revoking says nothing about expiry and must move nothing; '
              'the two-second delay makes any re-derivation from "now" '
              'visible');
    });

    test('an enrollment cannot postpone its own retirement with enroll:update',
        () async {
      // A write that says nothing about expiry must not move expiry. The
      // metadata builder re-derives expiresAt from the retained ttl, so
      // without an asserted carry one enroll:update per grace period would
      // renew a capped credential indefinitely and the cap would be advisory.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);
      await authenticateAsEnrollment(childId);

      final capped = (await enrollmentRecord(owner, parentId));
      final DateTime deadline = DateTime.parse(capped.metaData['expiresAt']);

      await Future.delayed(Duration(seconds: 2));

      OutboundConnectionFactory predecessor = await newConnection();
      expect(
          (await predecessor.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: parentId))
              .trim(),
          'data:success');
      String response = await predecessor.sendRequestToServer(
          'enroll:update:{"enrollmentId":"$parentId","metadata":{"note":"x"}}');
      expect(response, startsWith('data:'), reason: response);

      expect(
          DateTime.parse(
              (await enrollmentRecord(owner, parentId)).metaData['expiresAt']),
          deadline,
          reason: 'amending an enrollment must leave its deadline exactly '
              'where it was; a two-second delay makes any re-derivation from '
              '"now" visible');
    });

    test('storing a successor does not cap the predecessor', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      await selfEnrollId(parentId);

      expect((await enrollmentRecord(owner, parentId)).metaData['expiresAt'],
          isNull,
          reason: 'storing a successor proves only that the atServer wrote a '
              'record. The successor\'s APKAM private half lives '
              'client-side, so a keyfile write that failed would leave it '
              'existing here and nowhere else — and the predecessor is by '
              'then the only credential that still works');
    });

    test(
        'the cap is armed by the successor\'s first authentication, and '
        're-arms for each sibling', () async {
      // A deadline fixed by the first sibling's upgrade would strand every
      // laggard whose next run fell outside that window.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String firstId = await selfEnrollId(parentId);
      await authenticateAsEnrollment(firstId);
      DateTime firstCap = DateTime.parse(
          (await enrollmentRecord(owner, parentId)).metaData['expiresAt']);

      await Future.delayed(Duration(seconds: 2));

      String secondId = await selfEnrollId(parentId);
      expect(
          DateTime.parse(
              (await enrollmentRecord(owner, parentId)).metaData['expiresAt']),
          firstCap,
          reason: 'control: the second retrofit alone moves nothing — it is '
              'the authentication that arms, not the enrolment');

      await authenticateAsEnrollment(secondId);
      DateTime secondCap = DateTime.parse(
          (await enrollmentRecord(owner, parentId)).metaData['expiresAt']);

      expect(secondCap.isAfter(firstCap), isTrue,
          reason: 'the second sibling proving itself must push the '
              'predecessor\'s expiry out, not leave the first sibling\'s '
              'deadline in place');
    });

    test('a successor re-authenticating does not push the deadline out again',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String childId = await selfEnrollId(parentId);
      await authenticateAsEnrollment(childId);
      DateTime firstCap = DateTime.parse(
          (await enrollmentRecord(owner, parentId)).metaData['expiresAt']);

      await Future.delayed(Duration(seconds: 2));
      await authenticateAsEnrollment(childId);

      expect(
          DateTime.parse(
              (await enrollmentRecord(owner, parentId)).metaData['expiresAt']),
          firstCap,
          reason: 'a successor authenticates on every reconnect. Arming on '
              'each one would rewrite a full grace period onto the '
              'predecessor forever and it would never retire at all');
    });
  });

  /// Revoking an enrollment revokes everything that replaced it, to any
  /// depth. The unit suite pins the decisions; only over the wire is the
  /// CONSEQUENCE observable — a cascaded enrollment stops authenticating.
  group('Revocation cascades to descendants', () {
    Future<String> stateOf(OutboundConnectionFactory owner, String id) async =>
        (await enrollmentRecord(owner, id)).value['approval']['state'];

    /// Authenticates as [id] and reports what happened. A refused APKAM
    /// authentication may close the socket rather than answer, so a throw is
    /// a refusal too and must not be read as a broken fixture.
    Future<String> tryAuthenticateAs(String id) async {
      try {
        return (await (await newConnection()).authenticateConnection(
                authType: AuthType.apkam, enrollmentId: id))
            .trim();
      } catch (e) {
        return 'threw: $e';
      }
    }

    test('a successor stops authenticating when the enrollment it replaced is '
        'revoked', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);

      // The control. Without it a failure after the revoke could equally be a
      // successor that never worked.
      expect(await tryAuthenticateAs(childId), 'data:success',
          reason: 'precondition: the successor authenticates while its '
              'predecessor stands');

      String response = await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$parentId"}');
      expect(response, startsWith('data:'), reason: response);
      expect(
          jsonDecode(response.replaceFirst('data:', ''))[
              'cascadedEnrollmentIds'],
          [childId],
          reason: 'the revoke reports what it took with it');

      expect(await stateOf(owner, childId), 'revoked');
      expect(await tryAuthenticateAs(childId), isNot('data:success'),
          reason: 'a successor that still authenticates after the revocation '
              'of what it replaced defeats revocation through the very '
              'feature that created it');
    });

    test('the cascade reaches a grandchild, not just a child', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);
      String grandchildId = await selfEnrollId(childId);

      expect(await tryAuthenticateAs(grandchildId), 'data:success',
          reason: 'precondition');

      String response = await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$parentId"}');
      expect(response, startsWith('data:'), reason: response);

      expect(await stateOf(owner, grandchildId), 'revoked',
          reason: 'a self-enrolled enrollment can itself self-enroll, so a '
              'one-level cascade would leave this one on every roster');
      expect(await tryAuthenticateAs(grandchildId), isNot('data:success'));
    });

    test('un-revoking a descendant is refused while what it replaced stays '
        'revoked', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);
      await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$parentId"}');
      expect(await stateOf(owner, childId), 'revoked', reason: 'precondition');

      String refused = await owner
          .sendRequestToServer('enroll:unrevoke:{"enrollmentId":"$childId"}');
      expect(refused, startsWith('error:'),
          reason: 'without this the cascade is one-way: un-revoking a '
              'descendant while its predecessor stays revoked restores the '
              'orphan the cascade removed. Got: $refused');

      // The control: once the predecessor is back, the descendant may be too.
      // Otherwise the refusal above would be satisfied by an un-revoke that
      // never works at all.
      expect(
          await owner.sendRequestToServer(
              'enroll:unrevoke:{"enrollmentId":"$parentId"}'),
          startsWith('data:'));
      expect(
          await owner.sendRequestToServer(
              'enroll:unrevoke:{"enrollmentId":"$childId"}'),
          startsWith('data:'));
      expect(await stateOf(owner, childId), 'approved');
    });

    test('a connection already open on a cascaded enrollment is dropped',
        () async {
      // The cascade changes a stored status; on its own that binds nothing
      // until the holder next reconnects. A descendant sitting on an open
      // authenticated connection would go on working in the meantime, which
      // is most of what the cascade exists to stop.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId);

      OutboundConnectionFactory child = await newConnection();
      expect(
          (await child.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: childId))
              .trim(),
          'data:success');

      String key = 'drop-probe-${Uuid().v4().hashCode}.wavi$atSign';
      // The control, on this very connection and this very command: without
      // it a failure afterwards could be an unauthorised verb rather than a
      // dropped connection.
      expect(await child.sendRequestToServer('update:$key before'),
          startsWith('data:'),
          reason: 'precondition: the successor\'s connection is live and '
              'authorised for this key');

      await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$parentId"}');

      String after;
      try {
        after = await child.sendRequestToServer('update:$key after',
            maxWaitMilliSeconds: 3000);
      } catch (e) {
        // The server closes the socket, so the write or the read may throw
        // rather than answer. That is the drop, not a broken fixture.
        after = 'threw: $e';
      }
      expect(after, isNot(startsWith('data:')),
          reason: 'the connection held by a cascaded enrollment must not '
              'survive the revoke. Got: $after');
    });

    test('an ordinary revoke response carries no cascade field', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String id =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String response =
          await owner.sendRequestToServer('enroll:revoke:{"enrollmentId":"$id"}');
      expect(
          (jsonDecode(response.replaceFirst('data:', '')) as Map)
              .containsKey('cascadedEnrollmentIds'),
          isFalse,
          reason: 'an enrollment that replaced nothing has no descendants, '
              'and its revoke response must keep the shape it always had');
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
          signingAlgo: 'mldsa65', apsk: composed);

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
          signingAlgo: 'mldsa65');

      expect(
          await apskValue(owner, childId),
          contains('key not found : public:_apsk.$childId.a.__e$atSign '
              'does not exist in keystore'));
    });

    test('apskLegacy is published as the BARE string a deployed consumer reads',
        () async {
      // This is the arm only the wire can settle. Every deployed `_apsk`
      // consumer base64-decodes what it fetches as an RSA key, so what has to
      // be true is a property of the BYTES a verifier resolves, not of the
      // enrollment record: no quotes, no escaping, nothing the server added.
      const bare =
          'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAfunctionaltestkey';

      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String childId = await selfEnrollId(parentId,
          apskLegacy: bare);

      final resolved = await apskValue(owner, childId);
      expect(resolved, bare);
      expect(resolved, isNot(jsonEncode(bare)),
          reason: 'a quoted string is not what a bare-RSA parser reads, and '
              'a jsonDecode-based assertion would pass on both');
    });

    test('a request carrying BOTH apsk and apskLegacy is refused', () async {
      // One record publishes one value, so this is a client error rather than
      // a precedence question — and it is refused at the verb, which is the
      // only place the client finds out.
      OutboundConnectionFactory owner = await ownerConnection();
      String parentId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      final response = await selfEnroll(parentId,
          apsk: {
            'v': 1,
            'keys': [
              {'kid': 'k', 'use': 'sign', 'alg': 'mldsa65', 'pub': 'cA=='}
            ]
          },
          apskLegacy: 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A');

      expect(response, startsWith('error:'));
      expect(response, contains('mutually exclusive'),
          reason: 'matched on the message: several unrelated refusals on this '
              'path are also errors, so a startsWith check alone would go '
              'green on the wrong one');
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
