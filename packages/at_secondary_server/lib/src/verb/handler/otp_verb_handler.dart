import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'abstract_verb_handler.dart';

class OtpVerbHandler extends AbstractVerbHandler {
  // ignore: experimental_member_use
  static Otp otpVerb = Otp();

  @visibleForTesting
  static const Duration defaultOtpExpiry = Duration(minutes: 5);

  OtpVerbHandler(super.keyStore);

  @override
  bool accept(String command) => command.startsWith('otp:');

  @override
  Verb getVerb() => otpVerb;

  static final otpNamespace = '__otp';

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final operation = verbParams['operation'];
    if (!atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException('otp: requires authenticated connection');
    }
    switch (operation) {
      case 'get':
        // Issuing an OTP is an enrollment-management operation: only a
        // connection with access to the __manage namespace may do it (a
        // no-enrollmentId CRAM/owner connection is authorized too).
        if (!(await _hasManageNamespaceAccess(
            atConnection.metaData as InboundConnectionMetadata))) {
          throw UnAuthorizedException(
              'otp:get requires access to the __manage namespace');
        }
        String otp = generateOTP();
        // Extract the ttl from the verb parameters if supplied, or use the default value.
        int otpTtl = int.tryParse(verbParams[AtConstants.ttl] ?? '') ??
            defaultOtpExpiry.inMilliseconds;
        await savePasscode(otp,
            ttl: otpTtl,
            isSpp: false,
            namespaces: await _enrollmentNamespaces(
                atConnection.metaData as InboundConnectionMetadata));
        response.data = otp;
        break;
      case 'put':
        // The SPP is reusable and can admit an enrollment for any namespace,
        // so only a full-privilege connection may set it.
        if (!(await isRootPrivilegedConnection(
            atConnection.metaData as InboundConnectionMetadata))) {
          throw UnAuthorizedException(
              'otp:put requires full privilege (*:rw and __manage:rw)');
        }
        int sppTtl = int.tryParse(verbParams[AtConstants.ttl] ?? '') ?? -1;
        String? spp = verbParams['otp'];
        if (spp == null) {
          throw InvalidRequestException('otp:put requires a passcode');
        }
        await savePasscode(spp, ttl: sppTtl, isSpp: true);
        // NOTE the namespace-less SPP older atServers stored is removed, so an
        // SPP once replaced is never accepted again.
        await keyStore.remove(
            'private:spp${AtSecondaryServerImpl.getInstance().currentAtSign}');
        response.data = 'ok';
        break;
      case 'list':
        final listMetaData = atConnection.metaData as InboundConnectionMetadata;
        if (await isRootPrivilegedConnection(listMetaData)) {
          response.data = jsonEncode(await listPasscodes());
        } else if (await _hasManageNamespaceAccess(listMetaData)) {
          response.data = jsonEncode(await listPasscodes(
              scope: await _enrollmentNamespaces(listMetaData) ?? {}));
        } else {
          throw UnAuthorizedException(
              'otp:list requires access to the __manage namespace');
        }
        break;
      case 'delete':
        String? passcode = verbParams['otp'];
        if (passcode == null) {
          throw InvalidRequestException('otp:delete requires a passcode');
        }
        final deleteMetaData =
            atConnection.metaData as InboundConnectionMetadata;
        // NOTE a caller not allowed to delete still gets ok, so delete
        // never reveals which passcodes exist.
        if (await isRootPrivilegedConnection(deleteMetaData)) {
          await deletePasscode(passcode);
        } else if (await _hasManageNamespaceAccess(deleteMetaData)) {
          await deletePasscode(passcode,
              scope: await _enrollmentNamespaces(deleteMetaData) ?? {});
        }
        response.data = 'ok';
        break;
      default:
        throw InvalidSyntaxException('$operation is not a valid operation');
    }
  }

  /// This function generates a UUID and converts it into a 6-character alpha-numeric string.
  ///
  /// The process involves converting the UUID to a hashcode, then transforming the hashcode
  /// into its Hexatridecimal representation to obtain the desired alpha-numeric characters.
  ///
  /// Additionally, if the resulting OTP contains "0" or "O", they are replaced with different
  /// number or alphabet, respectively. If the length of the OTP is less than 6, "padRight"
  /// is utilized to extend and match the length.
  String generateOTP() {
    String otp = '';
    while (RegExp(r'\d').hasMatch(otp) == false) {
      var uuid = Uuid().v4();
      Random random = Random();
      otp = uuid.hashCode.toRadixString(36).toUpperCase();
      // If otp contains "0"(Zero) or "O" (alphabet) replace with a different number
      // or alphabet respectively.
      if (otp.contains('0') || otp.contains('O')) {
        for (int i = 0; i < otp.length; i++) {
          if (otp[i] == '0') {
            otp = otp.replaceFirst('0', (random.nextInt(8) + 1).toString());
          } else if (otp[i] == 'O') {
            otp = otp.replaceFirst('O', _generateRandomAlphabet());
          }
        }
      }
      if (otp.length < 6) {
        otp = otp.padRight(6, _generateRandomAlphabet());
      }
    }
    return otp;
  }

  static String passcodeKey(String passcode, {required bool isSpp}) {
    return isSpp
        ? 'private:spp.$otpNamespace'
            '${AtSecondaryServerImpl.getInstance().currentAtSign}'
        : 'private:${passcode.toLowerCase()}.$otpNamespace'
            '${AtSecondaryServerImpl.getInstance().currentAtSign}';
  }

  /// The passcode an OTP's key names: `<otp>` in `private:<otp>.__otp@<atSign>`.
  static String _passcodeFromKey(String key) =>
      key.substring('private:'.length, key.lastIndexOf('.$otpNamespace'));

  /// Stores [passcode]. An OTP's value also records [namespaces], the grants
  /// of the enrollment that issued it. The SPP's value stays the bare
  /// passcode, which isPasscodeValid compares.
  Future<void> savePasscode(String passcode,
      {required int ttl,
      required bool isSpp,
      Map<String, String>? namespaces}) async {
    await keyStore.put(
        passcodeKey(passcode, isSpp: isSpp),
        AtData()
          ..data = isSpp
              ? passcode
              : jsonEncode({
                  'passcode': passcode,
                  if (namespaces != null) 'namespaces': namespaces,
                })
          ..metaData = (AtMetaData()..ttl = ttl));
  }

  /// The live OTPs and the SPP, as `otp:list` returns them. A [scope] limits
  /// them to the OTPs it covers and leaves out the SPP; without one, as for
  /// a full-privilege caller, every passcode is listed.
  @visibleForTesting
  Future<List<Map<String, dynamic>>> listPasscodes(
      {Map<String, String>? scope}) async {
    final String atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    final String sppKey = passcodeKey('spp', isSpp: true);
    final String legacySppKey = 'private:spp$atSign';
    final List<String> keys = await (await keyStore.getKeys(
            regex: '^private:[^:@]+\\.$otpNamespace${RegExp.escape(atSign)}\$'))
        .toList();
    // NOTE isPasscodeValid falls back to the legacy SPP key only when the
    // current one is absent, so list does the same.
    if (!keys.contains(sppKey)) {
      keys.add(legacySppKey);
    }
    final List<Map<String, dynamic>> passcodes = [];
    for (final String key in keys) {
      final AtData? atData = await _getOrNull(key);
      if (atData?.data == null || !SecondaryUtil.isActiveKey(atData)) {
        continue;
      }
      final int expiresAt =
          atData!.metaData?.expiresAt?.millisecondsSinceEpoch ?? -1;
      // NOTE exact match: an OTP may itself start with "spp".
      if (key == sppKey || key == legacySppKey) {
        if (scope == null) {
          passcodes.add(
              {'type': 'spp', 'value': atData.data, 'expiresAt': expiresAt});
        }
        continue;
      }
      final otp = readOtp(atData.data!, keyPasscode: _passcodeFromKey(key));
      if (scope != null && !_mayManage(scope, otp.namespaces)) {
        continue;
      }
      passcodes.add({
        'type': 'otp',
        'value': otp.passcode,
        'expiresAt': expiresAt,
        if (otp.namespaces != null) 'namespaces': otp.namespaces,
      });
    }
    return passcodes;
  }

  /// Removes [passcode], or the SPP when [passcode] is `spp` in any case,
  /// including the namespace-less SPP key older clients stored. A [scope]
  /// limits it to an OTP that scope covers; the SPP and namespace-less keys
  /// then stay.
  @visibleForTesting
  Future<void> deletePasscode(String passcode,
      {Map<String, String>? scope}) async {
    final String atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    final bool isSpp = passcode.toLowerCase() == 'spp';
    if (scope != null) {
      if (isSpp) {
        return;
      }
      final String otpKey = passcodeKey(passcode, isSpp: false);
      final AtData? atData = await _getOrNull(otpKey);
      if (atData?.data != null &&
          _mayManage(scope, readOtp(atData!.data!).namespaces)) {
        await keyStore.remove(otpKey);
      }
      return;
    }
    if (isSpp) {
      await keyStore.remove(passcodeKey(passcode, isSpp: true));
      await keyStore.remove('private:spp$atSign');
      return;
    }
    await keyStore.remove(passcodeKey(passcode, isSpp: false));
  }

  Future<AtData?> _getOrNull(String key) async {
    try {
      return await keyStore.get(key);
    } on KeyNotFoundException {
      return null;
    }
  }

  String _generateRandomAlphabet() {
    int minAscii = 'A'.codeUnitAt(0); // ASCII value of 'A'
    int maxAscii = 'Z'.codeUnitAt(0); // ASCII value of 'Z'
    int randomAscii;
    do {
      randomAscii = minAscii + Random().nextInt((maxAscii - minAscii) + 1);
      // 79 is the ASCII value of "O". If randomAscii is 79, generate again.
    } while (randomAscii == 79);
    return String.fromCharCode(randomAscii);
  }

  int bytesToInt(List<int> bytes) {
    int result = 0;
    for (final b in bytes) {
      result = result * 256 + b;
    }
    return result;
  }

  /// Whether the connection holds access to the `__manage` namespace, which
  /// `otp:get`, `otp:list` and `otp:delete` require: a CRAM connection always
  /// does, any other connection is judged on the enrollment it carries, and a
  /// connection carrying none is refused.
  Future<bool> _hasManageNamespaceAccess(
      InboundConnectionMetadata atConnectionMetadata) async {
    return super.isAuthorized(atConnectionMetadata,
        namespace: EnrollmentConstants.enrollManageNamespace);
  }

  /// The grants of the enrollment this connection carries, or null for a
  /// CRAM connection or one carrying none.
  Future<Map<String, String>?> _enrollmentNamespaces(
      InboundConnectionMetadata atConnectionMetadata) async {
    final String? enrollmentId = atConnectionMetadata.enrollmentId;
    if (AbstractVerbHandler.isCramConnection(atConnectionMetadata) ||
        enrollmentId == null) {
      return null;
    }
    return (await resolveEnrollment(enrollmentId))?.namespaces;
  }

  /// An OTP record's value: `{"passcode", "namespaces"}`, or, for an OTP
  /// stored before OTPs carried namespaces, the bare passcode. A value that
  /// is neither is read as a namespace-less OTP, so only a full-privilege
  /// connection can list or delete it, under [keyPasscode] when given: the
  /// passcode its key names, which `otp:delete` takes.
  @visibleForTesting
  static ({String passcode, Map<String, String>? namespaces}) readOtp(
      String data,
      {String? keyPasscode}) {
    if (data.startsWith('{')) {
      try {
        final Map<String, dynamic> json = jsonDecode(data);
        final Map? namespaces = json['namespaces'] as Map?;
        return (
          passcode: json['passcode'] as String,
          namespaces:
              namespaces == null ? null : Map<String, String>.from(namespaces),
        );
      } catch (_) {
        // NOTE not the shape otp:get writes; read as namespace-less.
        return (passcode: keyPasscode ?? data, namespaces: null);
      }
    }
    return (passcode: data, namespaces: null);
  }

  /// Whether [scope] may manage an OTP issued with [namespaces]. One with
  /// none, issued before OTPs carried namespaces or by a CRAM connection, is
  /// for full-privilege connections only.
  bool _mayManage(Map<String, String> scope, Map<String, String>? namespaces) =>
      namespaces != null && namespaces.isNotEmpty && covers(scope, namespaces);

  /// Whether [held] is a superset of [wanted]: each namespace held with at
  /// least the same letters ("rw" covers "r"). `*` covers any other
  /// namespace, while `*` and `__manage` must be held literally, as in
  /// EnrollVerbHandler.verifyNoEscalation. Namespaces are folded with
  /// [canonicalAtKey], as the keystore folds key names.
  @visibleForTesting
  static bool covers(Map<String, String> held, Map<String, String> wanted) {
    final Map<String, String> heldFolded = held.map(
        (namespace, access) => MapEntry(canonicalAtKey(namespace), access));
    for (final entry in wanted.entries) {
      final String namespace = canonicalAtKey(entry.key);
      String? access = heldFolded[namespace];
      final bool isSpecial = namespace == EnrollmentConstants.allNamespaces ||
          namespace == EnrollmentConstants.enrollManageNamespace;
      if (access == null && !isSpecial) {
        access = heldFolded[EnrollmentConstants.allNamespaces];
      }
      if (access == null ||
          !entry.value.split('').every(access.split('').contains)) {
        return false;
      }
    }
    return true;
  }
}
