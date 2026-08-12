import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

class ETU {
  late EnrollVerbHandler evh;
  late OtpVerbHandler ovh;
  late UpdateVerbHandler uvh;
  late LookupVerbHandler lvh;
  late LocalLookupVerbHandler llvh;
  late ProxyLookupVerbHandler plvh;
  late String primaryEnId;

  Future<void> init() async {
    evh = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
    ovh = OtpVerbHandler(keyValueStore);
    uvh = UpdateVerbHandler(
      keyValueStore,
      statsNotificationService,
      notificationManager,
      alice,
    );
    lvh = LookupVerbHandler(
        keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
        accessLog: atAccessLog);
    llvh = LocalLookupVerbHandler(keyValueStore, enMgr);
    plvh = ProxyLookupVerbHandler(
        keyValueStore, mockOutboundClientManager, cacheManager,
        accessLog: atAccessLog);
    primaryEnId = await createPrimaryEnrollment();
  }

  Future<String> getOtp() async {
    inboundConnection.metaData.isAuthenticated = true;
    final r = Response();
    await ovh.processVerb(
        r, getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection);
    expect(r.isError, false);
    return r.data!;
  }

  /// [apsk] is the client-composed signing-key value and [apskLegacy] the bare
  /// RSA string a plain-legacy enrollment publishes instead. Leaving both null
  /// is the ordinary case and means no `_apsk` is published for this
  /// enrollment. Sending both is what a client is refused for, so the pair is
  /// exposed here rather than made exclusive — a test has to be able to send
  /// the refused combination.
  Future<String> createPendingEnrollment(
      {required String appName,
      required String deviceName,
      required Map<String, String> namespaces,
      required Duration? apkamKeysExpiryDuration,
      Map<String, dynamic>? apsk,
      String? apskLegacy}) async {
    final EnrollParams ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = 'apkam public key $appName $deviceName'
      ..encryptedAPKAMSymmetricKey =
          'encrypted apkam aes key $appName $deviceName'
      ..namespaces = namespaces
      ..apkamKeysExpiryDuration = apkamKeysExpiryDuration
      ..apsk = apsk
      ..apskLegacy = apskLegacy
      ..otp = await getOtp();

    final String enrollmentRequest = 'enroll:request:'
        '${jsonEncode(ep.toJson())}';
    final Response r = Response();
    inboundConnection.metaData.isAuthenticated = false;
    inboundConnection.metaData.authType = null;
    inboundConnection.metaData.sessionID =
        DateTime.now().millisecondsSinceEpoch.toString();
    await evh.processVerb(
      r,
      getVerbParam(VerbSyntax.enroll, enrollmentRequest),
      inboundConnection,
    );
    expect(r.isError, false);
    final Map m = jsonDecode(r.data!);
    expect(m['status'], EnrollmentStatus.pending.name);
    return m['enrollmentId'];
  }

  Future<void> approveEnrollment(
      String approverEnId, String enIdToApprove) async {
    inboundConnection.metaData.isAuthenticated = true;
    inboundConnection.metaData.enrollmentId = approverEnId;
    EnrollParams p = EnrollParams()
      ..enrollmentId = enIdToApprove
      ..encryptedDefaultEncryptionPrivateKey =
          'encrypted default encryption private key'
      ..encryptedDefaultSelfEncryptionKey =
          'encrypted default self encryption key';
    final approveCommand = 'enroll:approve:${jsonEncode(p.toJson())}';
    final r = Response();
    await evh.processVerb(
      r,
      getVerbParam(VerbSyntax.enroll, approveCommand),
      inboundConnection,
    );
    expect(r.isError, false);
    final m = jsonDecode(r.data!);
    expect(m['status'], EnrollmentStatus.approved.name);
    expect(m['enrollmentId'], enIdToApprove);
  }

  Future<void> revokeEnrollment(String revokerEnId, String enIdToRevoke) async {
    inboundConnection.metaData.isAuthenticated = true;
    inboundConnection.metaData.enrollmentId = revokerEnId;
    EnrollParams p = EnrollParams()..enrollmentId = enIdToRevoke;
    final revokeResponse = Response();
    await evh.processVerb(
      revokeResponse,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:revoke:${jsonEncode(p.toJson())}'),
      inboundConnection,
    );
    expect(revokeResponse.isError, false);
    final m = jsonDecode(revokeResponse.data!);
    expect(m['status'], EnrollmentStatus.revoked.name);
    expect(m['enrollmentId'], enIdToRevoke);
  }

  Future<void> unrevokeEnrollment(
      String unRevokerEnId, String enIdToUnRevoke) async {
    inboundConnection.metaData.isAuthenticated = true;
    inboundConnection.metaData.enrollmentId = unRevokerEnId;
    EnrollParams p = EnrollParams()..enrollmentId = enIdToUnRevoke;
    final revokeResponse = Response();
    await evh.processVerb(
      revokeResponse,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:unrevoke:${jsonEncode(p.toJson())}'),
      inboundConnection,
    );
    expect(revokeResponse.isError, false);
    final m = jsonDecode(revokeResponse.data!);
    expect(m['status'], EnrollmentStatus.approved.name);
    expect(m['enrollmentId'], enIdToUnRevoke);
  }

  Future<void> deleteEnrollment(String deleterEnId, String enIdToDelete) async {
    inboundConnection.metaData.isAuthenticated = true;
    inboundConnection.metaData.enrollmentId = deleterEnId;
    EnrollParams p = EnrollParams()..enrollmentId = enIdToDelete;
    final revokeResponse = Response();
    await evh.processVerb(
      revokeResponse,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:delete:${jsonEncode(p.toJson())}'),
      inboundConnection,
    );
    expect(revokeResponse.isError, false);
    final m = jsonDecode(revokeResponse.data!);
    expect(m['status'], 'deleted');
    expect(m['enrollmentId'], enIdToDelete);
  }

  Future<String> createPrimaryEnrollment(
      {Map<String, dynamic>? apsk, String? apskLegacy}) async {
    EnrollParams ep = EnrollParams()
      ..appName = 'primary'
      ..deviceName = 'primary'
      ..apkamPublicKey = 'apkam public key'
      ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key'
      ..apsk = apsk
      ..apskLegacy = apskLegacy
      ..namespaces = {'*': 'rw'};
    String enrollmentRequest = 'enroll:request:'
        '${jsonEncode(ep.toJson())}';
    Response r = Response();
    inboundConnection.metaData.isAuthenticated = true;
    inboundConnection.metaData.authType = AuthType.cram;
    inboundConnection.metaData.sessionID =
        DateTime.now().millisecondsSinceEpoch.toString();
    await evh.processVerb(
      r,
      getVerbParam(VerbSyntax.enroll, enrollmentRequest),
      inboundConnection,
    );
    expect(r.isError, false);
    Map m = jsonDecode(r.data!);
    expect(m['status'], EnrollmentStatus.approved.name);
    return m['enrollmentId'];
  }

  Future<void> verifyKeyStoreState(
      List<String> allCreated, List<String> deletedOrExpired,
      {required bool cleanedUp}) async {
    // int i = 0;
    for (final enId in allCreated) {
      bool enDeleted = deletedOrExpired.contains(enId);
      // enrollment should exist unless was deleted
      bool enrollmentShouldExist = !enDeleted;
      // ancillary keys should exist if not deleted, or if deleted but not cleanedUp
      bool ancillaryKeysShouldExist = !enDeleted || (enDeleted && !cleanedUp);
      // print ('checking ${i++} deleted: $enDeleted cleanedUp: $cleanedUp ancillaryShouldExist: $ancillaryKeysShouldExist');
      await expectLater(
          await keyValueStore.exists(enMgr.buildEnrollmentKey(enId)),
          enrollmentShouldExist);
      await expectLater(await keyValueStore.exists(enMgr.keyForPEK(enId)),
          ancillaryKeysShouldExist);
      await expectLater(await keyValueStore.exists(enMgr.keyForSEK(enId)),
          ancillaryKeysShouldExist);
    }
  }

  /// Returns (List of all enrollment IDs, List of IDS of enrollments with ttl)
  Future<(List<String>, List<String>)> createEnrollments({
    /// number of enrollments to create
    required int n,

    /// every m'th enrollment will have a ttl set
    /// the ttl to set for every m'th enrollment
    int m = 1000,
    int ttl = 50,
  }) async {
    List<String> allEnIds = [];
    List<String> withTtlEnIds = [];
    // Create and approve some enrollments
    for (int i = 0; i < n; i++) {
      final bool withTtl = (i + 1) % m == 0;
      final enId = await createPendingEnrollment(
        appName: 'app_${i + 1}',
        deviceName: 'test',
        namespaces: {'app_${i + 1}': 'rw', 'test': 'r'},
        apkamKeysExpiryDuration: withTtl ? Duration(milliseconds: ttl) : null,
      );
      allEnIds.add(enId);
      if (withTtl) {
        withTtlEnIds.add(enId);
      }
      await approveEnrollment(primaryEnId, enId);
    }

    expect(allEnIds.length, n);

    return (allEnIds, withTtlEnIds);
  }

  /// Creates 3 public keys, 3 self keys and 3 shared keys
  Future<(List<String>, List<String>)> createSomePerEnrollmentData(
      String enId) async {
    inboundConnection.metaData.isAuthenticated = true;
    inboundConnection.metaData.enrollmentId = enId;

    final List<String> keys = [];
    final List<String> values = [];
    for (int i = 1; i <= 3; i++) {
      Response r;
      String key;
      String value;
      // public key
      r = Response();
      key = 'public:public_foo_$i.my_app'
          '.${AbstractVerbHandler.enrollmentReservedNamespace(enId)}'
          '$alice';
      value = 'public_foo_$i data';
      await uvh.processVerb(
          Response(),
          getVerbParam(VerbSyntax.update, 'update:$key $value'),
          inboundConnection);
      expect(r.isError, false);
      keys.add(key);
      values.add(value);

      // self key
      r = Response();
      key = '$alice:self_foo_$i.my_app'
          '.${AbstractVerbHandler.enrollmentReservedNamespace(enId)}'
          '$alice';
      value = 'self_foo_$i data';
      await uvh.processVerb(
          Response(),
          getVerbParam(VerbSyntax.update, 'update:$key $value'),
          inboundConnection);
      expect(r.isError, false);
      keys.add(key);
      values.add(value);

      // shared key
      r = Response();
      key = '$bob:shared_foo_$i.my_app'
          '.${AbstractVerbHandler.enrollmentReservedNamespace(enId)}'
          '$alice';
      value = 'shared_foo_$i data';
      await uvh.processVerb(
          Response(),
          getVerbParam(VerbSyntax.update, 'update:$key $value'),
          inboundConnection);
      expect(r.isError, false);
      keys.add(key);
      values.add(value);
    }

    expect(keys.length, 9);
    expect(values.length, 9);

    return (keys, values);
  }
}
