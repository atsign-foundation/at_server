import 'dart:collection';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
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
        await savePasscode(otp, ttl: otpTtl, isSpp: false);
        response.data = otp;
        break;
      case 'put':
        // Only client connections which have access to the __manage namespace
        // are allowed to store the semi-permanent passcode.
        if (!(await _hasManageNamespaceAccess(
            atConnection.metaData as InboundConnectionMetadata))) {
          throw InvalidRequestException(
              'Client not allowed to not store semi permanent pass code');
        }
        int sppTtl = int.tryParse(verbParams[AtConstants.ttl] ?? '') ?? -1;
        String? spp = verbParams['otp'];
        if (spp == null) {
          throw InvalidRequestException('otp:put requires a passcode');
        }
        await savePasscode(spp, ttl: sppTtl, isSpp: true);
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

  Future<void> savePasscode(String passcode,
      {required int ttl, required bool isSpp}) async {
    await keyStore.put(
        passcodeKey(passcode, isSpp: isSpp),
        AtData()
          ..data = passcode
          ..metaData = (AtMetaData()..ttl = ttl));
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

  /// Whether the connection holds access to the `__manage` namespace — required
  /// for enrollment-management operations (issuing an OTP via `otp:get`, storing
  /// a semi-permanent passcode via `otp:put`). A connection with no enrollmentId
  /// (CRAM / owner) is authorized, preserving the initial-enrollment bootstrap.
  Future<bool> _hasManageNamespaceAccess(
      InboundConnectionMetadata atConnectionMetadata) async {
    return super.isAuthorized(atConnectionMetadata,
        namespace: EnrollmentConstants.enrollManageNamespace);
  }
}
