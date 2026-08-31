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
/// published `_apsk`, and whether the successor can actually PKAM-authenticate —
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
  /// ordinary OTP flow, and returns its enrollment id. This is the predecessor a
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
  /// [predecessorId], and returns the raw server response.
  /// [namespaces] is optional, mirroring the wire: a retrofit that omits
  /// it inherits its predecessor's grants, and one that states them must
  /// state exactly them.
  Future<String> selfEnroll(String predecessorId,
      {Map<String, String>? namespaces,
      String? appName,
      String? deviceName,
      int? apkamKeysExpiryInMillis,
      String? signingAlgo,
      Map<String, dynamic>? apsk,
      String? apskLegacy}) async {
    OutboundConnectionFactory predecessor = await newConnection();
    expect(
        (await predecessor.authenticateConnection(
                authType: AuthType.apkam, enrollmentId: predecessorId))
            .trim(),
        'data:success',
        reason: 'the predecessor must be able to authenticate before it self-enrols');
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
    return (await predecessor.sendRequestToServer(
            'enroll:request:{"appName":"${appName ?? 'successor-${Uuid().v4().hashCode}'}","deviceName":"${deviceName ?? 'device-${Uuid().v4().hashCode}'}","apkamPublicKey":"$apkamPublicKey"$nsField$expiry$algo$apskField$apskLegacyField}'))
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
  Future<String> selfEnrollId(String predecessorId,
      {Map<String, String>? namespaces,
      String? appName,
      String? deviceName,
      int? apkamKeysExpiryInMillis,
      String? signingAlgo,
      Map<String, dynamic>? apsk,
      String? apskLegacy}) async {
    String response = await selfEnroll(predecessorId,
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
  /// the written ttl and the recorded predecessor are observable.
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String successorId =
          await selfEnrollId(predecessorId);

      // The successor is not merely recorded: it authenticates.
      OutboundConnectionFactory successor = await newConnection();
      expect(
          (await successor.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: successorId))
              .trim(),
          'data:success');
    });

    test('the successor records what it replaced, which is what the cascade '
        'walks', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);

      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['parentEnrollmentId'], predecessorId);
      expect(successor.value['namespaces'], {'wavi': 'rw'},
          reason: 'the successor carries its predecessor\'s grants, so it '
              'holds rw here and not the r an earlier contract let a '
              'caller ask for');
      expect(successor.value['approval']['state'], 'approved');
    });

    test('a self-enrolled successor needs no encrypted APKAM symmetric key',
        () async {
      // A PQ self-enrollment conveys its legacy material client-side, sealed
      // to its own new key package, so the field the ordinary path demands is
      // absent here.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);

      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['encryptedAPKAMSymmetricKey'], isNull);
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
      String predecessorId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'},
          appName: appName,
          deviceName: deviceName);

      // Same names, twice, on the self-enrollment branch: both approved.
      await selfEnrollId(predecessorId,
          appName: appName,
          deviceName: deviceName);
      await selfEnrollId(predecessorId,
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

  group('A self-enrollment may not escalate beyond its predecessor', () {
    test('a namespace the predecessor does not hold is refused', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String response =
          await selfEnroll(predecessorId, namespaces: {'buzz': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(
          error['errorDescription'],
          contains('Requested namespace "buzz:rw" exceeds the predecessor '
              'enrollment\'s grants'));
    });

    test('broader access letters on a held namespace are refused', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId = await createApprovedEnrollment(owner,
          namespaces: {'atmosphere': 'r'});

      String response =
          await selfEnroll(predecessorId, namespaces: {'atmosphere': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(error['errorDescription'],
          contains('Requested namespace "atmosphere:rw" exceeds'));
    });

    test('a wildcard predecessor cannot mint __manage', () async {
      // `*` does not imply `__manage` anywhere else in the server, and it must
      // not here — otherwise any `*` keyfile could self-spawn an enrollment
      // that administers every other enrollment.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'*': 'rw'});

      String response =
          await selfEnroll(predecessorId, namespaces: {'__manage': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(error['errorDescription'],
          contains('Requested namespace "__manage:rw" exceeds'));
    });

    test('a request naming a subset of a wildcard predecessor is refused', () async {
      // A * predecessor used to cover any ordinary namespace at its letters, so
      // this succeeded and minted a successor that could not do what the
      // enrollment it replaced could.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'*': 'rw'});

      String response = await selfEnroll(predecessorId,
          namespaces: {'a-namespace-never-named': 'rw'});
      Map error = jsonDecode(response.replaceFirst('error:', ''));
      expect(error['errorCode'], 'AT0009');
      expect(error['errorDescription'], contains('carries its grants'));
    });

    test('a wildcard predecessor is inherited verbatim when nothing is named',
        () async {
      // The positive half: the rule is equality, not a refusal of everything.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'*': 'rw'});

      String successorId = await selfEnrollId(predecessorId);
      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['namespaces'], {'*': 'rw'});
    });

    test('an empty namespace set inherits, rather than being refused',
        () async {
      // Stating nothing is how a request asks to inherit: a retrofit does not
      // choose its grants, so it need not name them.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String response = await selfEnroll(predecessorId, namespaces: {});
      expect(response, startsWith('data:'),
          reason: 'an empty map states nothing, and the successor takes its '
              'predecessor\'s grants: $response');
      final successorId =
          jsonDecode(response.replaceFirst('data:', ''))['enrollmentId'];
      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['namespaces'], {'wavi': 'rw'});
    });
  });

  group('A self-enrolled successor expires, and may not outlive its predecessor', () {
    // One hour, so a successor asking for longer, for "never", or for a negative
    // value has something to be clamped against.
    const int oneHourMs = 3600000;

    test('a successor inherits the predecessor\'s key-expiry posture', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String successorId = await selfEnrollId(predecessorId);
      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['apkamKeysExpiryInMillis'], oneHourMs);
      // The posture is not merely recorded, it is written as the record's ttl
      // — the hole that made an inherited expiry into immortality.
      expect(successor.metaData['ttl'], oneHourMs);
      expect(successor.metaData['expiresAt'], isNotNull);
    });

    test('a successor may state a SHORTER expiry than its predecessor', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String successorId = await selfEnrollId(predecessorId,
          apkamKeysExpiryInMillis: 60000);
      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['apkamKeysExpiryInMillis'], 60000);
      expect(successor.metaData['ttl'], 60000);
    });

    test('a successor may not state an expiry that outlives its predecessor', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String successorId = await selfEnrollId(predecessorId,
          apkamKeysExpiryInMillis: 999999999);
      final successor = await enrollmentRecord(owner, successorId);
      // Clamped to the predecessor's, not refused: a client asking for longer
      // without knowing is corrected rather than broken.
      expect(successor.value['apkamKeysExpiryInMillis'], oneHourMs);
      expect(successor.metaData['ttl'], oneHourMs);
    });

    test('a successor may not state "never expires" against a bounded predecessor',
        () async {
      // Zero is the keystore's "never expires" — the route by which a stolen,
      // hour-bound keyfile would mint itself a permanent credential.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String successorId = await selfEnrollId(predecessorId,
          apkamKeysExpiryInMillis: 0);
      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['apkamKeysExpiryInMillis'], oneHourMs);
      expect(successor.metaData['ttl'], oneHourMs);
    });

    test('a negative stated expiry is not honoured', () async {
      // A negative value skips the ttl write altogether, so it is the same
      // ask as "never expires" by a different route.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId = await createApprovedEnrollment(owner,
          namespaces: {'wavi': 'rw'}, apkamKeysExpiryInMillis: oneHourMs);

      String successorId = await selfEnrollId(predecessorId,
          apkamKeysExpiryInMillis: -1);
      final successor = await enrollmentRecord(owner, successorId);
      expect(successor.value['apkamKeysExpiryInMillis'], oneHourMs);
      expect(successor.metaData['ttl'], oneHourMs);
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);
      await authenticateAsEnrollment(successorId);

      expect((await enrollmentRecord(owner, predecessorId)).metaData['expiresAt'],
          isNotNull,
          reason: 'control: the predecessor really is capped, so the '
              'authentication below is a capped credential authenticating and '
              'not an uncapped one');

      OutboundConnectionFactory predecessor = await newConnection();
      expect(
          (await predecessor.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: predecessorId))
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);

      expect((await enrollmentRecord(owner, successorId)).value,
          isNot(contains('predecessorCapArmedAt')),
          reason: 'absent until it arms, so an unarmed successor is '
              'distinguishable from an armed one at rest');

      await authenticateAsEnrollment(successorId);

      final armed = (await enrollmentRecord(owner, successorId)).value;
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);
      await authenticateAsEnrollment(successorId);

      final capped = (await enrollmentRecord(owner, predecessorId));
      final DateTime deadline = DateTime.parse(capped.metaData['expiresAt']);

      await Future.delayed(Duration(seconds: 2));

      OutboundConnectionFactory predecessor = await newConnection();
      expect(
          (await predecessor.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: predecessorId))
              .trim(),
          'data:success');
      String response = await predecessor.sendRequestToServer(
          'enroll:update:{"enrollmentId":"$predecessorId","metadata":{"note":"x"}}');
      expect(response, startsWith('data:'), reason: response);

      expect(
          DateTime.parse(
              (await enrollmentRecord(owner, predecessorId)).metaData['expiresAt']),
          deadline,
          reason: 'amending an enrollment must leave its deadline exactly '
              'where it was; a two-second delay makes any re-derivation from '
              '"now" visible');
    });

    test('storing a successor does not cap the predecessor', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      await selfEnrollId(predecessorId);

      expect((await enrollmentRecord(owner, predecessorId)).metaData['expiresAt'],
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String firstId = await selfEnrollId(predecessorId);
      await authenticateAsEnrollment(firstId);
      DateTime firstCap = DateTime.parse(
          (await enrollmentRecord(owner, predecessorId)).metaData['expiresAt']);

      await Future.delayed(Duration(seconds: 2));

      String secondId = await selfEnrollId(predecessorId);
      expect(
          DateTime.parse(
              (await enrollmentRecord(owner, predecessorId)).metaData['expiresAt']),
          firstCap,
          reason: 'control: the second retrofit alone moves nothing — it is '
              'the authentication that arms, not the enrolment');

      await authenticateAsEnrollment(secondId);
      DateTime secondCap = DateTime.parse(
          (await enrollmentRecord(owner, predecessorId)).metaData['expiresAt']);

      expect(secondCap.isAfter(firstCap), isTrue,
          reason: 'the second sibling proving itself must push the '
              'predecessor\'s expiry out, not leave the first sibling\'s '
              'deadline in place');
    });

    test('a successor re-authenticating does not push the deadline out again',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      String successorId = await selfEnrollId(predecessorId);
      await authenticateAsEnrollment(successorId);
      DateTime firstCap = DateTime.parse(
          (await enrollmentRecord(owner, predecessorId)).metaData['expiresAt']);

      await Future.delayed(Duration(seconds: 2));
      await authenticateAsEnrollment(successorId);

      expect(
          DateTime.parse(
              (await enrollmentRecord(owner, predecessorId)).metaData['expiresAt']),
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);

      // The control. Without it a failure after the revoke could equally be a
      // successor that never worked.
      expect(await tryAuthenticateAs(successorId), 'data:success',
          reason: 'precondition: the successor authenticates while its '
              'predecessor stands');

      String response = await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$predecessorId"}');
      expect(response, startsWith('data:'), reason: response);
      expect(
          jsonDecode(response.replaceFirst('data:', ''))[
              'cascadedEnrollmentIds'],
          [successorId],
          reason: 'the revoke reports what it took with it');

      expect(await stateOf(owner, successorId), 'revoked');
      expect(await tryAuthenticateAs(successorId), isNot('data:success'),
          reason: 'a successor that still authenticates after the revocation '
              'of what it replaced defeats revocation through the very '
              'feature that created it');
    });

    test('the cascade reaches a successor\'s successor, not just the first',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);
      String laterSuccessorId = await selfEnrollId(successorId);

      expect(await tryAuthenticateAs(laterSuccessorId), 'data:success',
          reason: 'precondition');

      String response = await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$predecessorId"}');
      expect(response, startsWith('data:'), reason: response);

      expect(await stateOf(owner, laterSuccessorId), 'revoked',
          reason: 'a self-enrolled enrollment can itself self-enroll, so a '
              'one-level cascade would leave this one on every roster');
      expect(await tryAuthenticateAs(laterSuccessorId), isNot('data:success'));
    });

    test('un-revoking a descendant is refused while what it replaced stays '
        'revoked', () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);
      await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$predecessorId"}');
      expect(await stateOf(owner, successorId), 'revoked', reason: 'precondition');

      String refused = await owner
          .sendRequestToServer('enroll:unrevoke:{"enrollmentId":"$successorId"}');
      expect(refused, startsWith('error:'),
          reason: 'without this the cascade is one-way: un-revoking a '
              'descendant while its predecessor stays revoked restores the '
              'orphan the cascade removed. Got: $refused');

      // The control: once the predecessor is back, the descendant may be too.
      // Otherwise the refusal above would be satisfied by an un-revoke that
      // never works at all.
      expect(
          await owner.sendRequestToServer(
              'enroll:unrevoke:{"enrollmentId":"$predecessorId"}'),
          startsWith('data:'));
      expect(
          await owner.sendRequestToServer(
              'enroll:unrevoke:{"enrollmentId":"$successorId"}'),
          startsWith('data:'));
      expect(await stateOf(owner, successorId), 'approved');
    });

    test('a connection already open on a cascaded enrollment is dropped',
        () async {
      // The cascade changes a stored status; on its own that binds nothing
      // until the holder next reconnects. A descendant sitting on an open
      // authenticated connection would go on working in the meantime, which
      // is most of what the cascade exists to stop.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);

      OutboundConnectionFactory successor = await newConnection();
      expect(
          (await successor.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: successorId))
              .trim(),
          'data:success');

      String key = 'drop-probe-${Uuid().v4().hashCode}.wavi$atSign';
      // The control, on this very connection and this very command: without
      // it a failure afterwards could be an unauthorised verb rather than a
      // dropped connection.
      expect(await successor.sendRequestToServer('update:$key before'),
          startsWith('data:'),
          reason: 'precondition: the successor\'s connection is live and '
              'authorised for this key');

      await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$predecessorId"}');

      String after;
      try {
        after = await successor.sendRequestToServer('update:$key after',
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

    test('a revocation time is served on enroll:list, on both the named '
        'target and the cascaded successor', () async {
      // The point of putting `revokedAt` on the enrollment VALUE: the record
      // is serialised whole, so the stamp leaves the server rather than
      // staying an internal detail. Only over the wire is that observable.
      //
      // Read here on the OWNER's connection, which is what sees every record.
      // `enroll:list` narrows to the caller's own record unless the caller is
      // legacy-PKAM or holds `__manage`, so this asserts that the stamp is
      // served — not that any given client can see another enrollment's.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId);

      Future<Map> listed() async => jsonDecode(
          (await owner.sendRequestToServer('enroll:list'))
              .replaceFirst('data:', '')
              .trim()) as Map;

      // The control. Without it "the field is present after" is satisfied by
      // a field that was always there.
      final Map before = await listed();
      for (final e in before.entries.where((e) =>
          e.key.contains(predecessorId) || e.key.contains(successorId))) {
        expect((e.value as Map)['revokedAt'], isNull,
            reason: 'nothing is revoked yet, so no record may carry a '
                'revocation time: ${e.key}');
      }

      await owner
          .sendRequestToServer('enroll:revoke:{"enrollmentId":"$predecessorId"}');

      final Map after = await listed();
      final matched = after.entries
          .where((e) =>
              e.key.contains(predecessorId) || e.key.contains(successorId))
          .toList();
      expect(matched.length, 2,
          reason: 'both the named target and the successor the cascade took '
              'must still be listed, or the loop below asserts nothing');
      for (final e in matched) {
        final stamp = (e.value as Map)['revokedAt'];
        expect(stamp, isNotNull, reason: '${e.key} is revoked and must say when');
        expect(() => DateTime.parse(stamp as String), returnsNormally,
            reason: 'the wire contract is ISO-8601, which is what a client '
                'compares against other server-stamped times');
      }
    });

    test('enroll:infons reports the namespace\'s last revocation over the wire',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      String holderA =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String holderB =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      // infons needs an APKAM connection holding the namespace, so it is asked
      // as holderA — not on the owner's CRAM connection, which is refused.
      OutboundConnectionFactory asA = await newConnection();
      expect(
          (await asA.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: holderA))
              .trim(),
          'data:success');

      Future<Map> infons() async => jsonDecode(
          (await asA.sendRequestToServer('enroll:infons:wavi'))
              .replaceFirst('data:', '')
              .trim()) as Map;

      // The key is always present. Its VALUE is not asserted to be null here:
      // this atSign is shared across the whole pack and earlier tests in this
      // very file revoke wavi holders, so 'wavi' usually arrives with a
      // revocation already on record. The null case is pinned in the unit
      // suite, where the store is this test's own.
      final before = await infons();
      expect(before.containsKey('lastRevokedAt'), isTrue,
          reason: 'an absent key and a key a client failed to parse are the '
              'same thing to a careless reader; the key is always there');

      await owner.sendRequestToServer('enroll:revoke:{"enrollmentId":"$holderB"}');

      // Asserted by VALUE against the same authority: holderB's own stamp,
      // read off its record. Comparing against DateTime.now() here would be
      // measuring clock agreement between this process and the server.
      final listed = jsonDecode((await owner.sendRequestToServer('enroll:list'))
          .replaceFirst('data:', '')
          .trim()) as Map;
      final holderBRecord = listed.entries
          .firstWhere((e) => e.key.contains(holderB))
          .value as Map;
      expect(holderBRecord['revokedAt'], isNotNull,
          reason: 'precondition: the revoke stamped the record');

      final after = await infons();
      expect(after['lastRevokedAt'], holderBRecord['revokedAt'],
          reason: 'the namespace reports the most recent revocation of an '
              'enrollment holding it, and holderB was just revoked');
      expect(after['lastRevokedAt'], isNot(before['lastRevokedAt']),
          reason: 'and it MOVED — otherwise this passes on whatever the '
              'namespace already carried when the test started');

      // And the roster is untouched by any of it — `enroll:listns` returns
      // what it always did, which is what lets this land without a client
      // change.
      final roster = jsonDecode(
          (await asA.sendRequestToServer('enroll:listns:wavi'))
              .replaceFirst('data:', '')
              .trim()) as List;
      expect(roster, isNotEmpty);
      for (final row in roster) {
        expect((row as Map).keys.toSet(),
            {'enrollmentId', 'access', 'apkamPubKey', 'metadata'});
      }
    });

    test('enroll:infons is refused on a connection that is not APKAM',
        () async {
      OutboundConnectionFactory owner = await ownerConnection();
      final response = await owner.sendRequestToServer('enroll:infons:wavi');
      expect(response, startsWith('error:'),
          reason: 'the namespace-scoped verbs are gated on an APKAM '
              'enrollment holding the namespace, and the owner\'s CRAM '
              'connection holds no enrollment at all. Got: $response');
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId,
          signingAlgo: 'mldsa65', apsk: composed);

      expect(jsonDecode(await apskValue(owner, successorId)), composed);
    });

    test('an enrollment that sends no apsk gets no _apsk record', () async {
      // The atServer composes nothing from (apkamPublicKey, signingAlgo):
      // PKAM verification reads the enrollment record, so this key is the
      // enrollee's to publish from its own connection, or to go without.
      OutboundConnectionFactory owner = await ownerConnection();
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId,
          signingAlgo: 'mldsa65');

      expect(
          await apskValue(owner, successorId),
          contains('key not found : public:_apsk.$successorId.a.__e$atSign '
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});
      String successorId = await selfEnrollId(predecessorId,
          apskLegacy: bare);

      final resolved = await apskValue(owner, successorId);
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
      String predecessorId =
          await createApprovedEnrollment(owner, namespaces: {'wavi': 'rw'});

      final response = await selfEnroll(predecessorId,
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
