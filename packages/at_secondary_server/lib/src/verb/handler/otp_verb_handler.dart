import 'dart:collection';
import 'dart:math';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/store/otp_store.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'abstract_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class OtpVerbHandler extends AbstractVerbHandler {
  static Otp otpVerb = Otp();

  @visibleForTesting
  Duration otpExpiryDuration = Duration(minutes: 5);

  static late OTPStore _otpStore;

  OtpVerbHandler(SecondaryKeyStore keyStore, {Duration? gcDuration})
      : super(keyStore) {
    gcDuration ??= Duration(minutes: AtSecondaryConfig.otpGCDurationInMins);
    _otpStore = OTPStore(gcDuration: gcDuration);
  }

  @override
  bool accept(String command) => command.startsWith('otp');

  @override
  Verb getVerb() => otpVerb;

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final operation = verbParams['operation'];
    if (verbParams[AtConstants.ttl] != null) {
      otpExpiryDuration =
          Duration(seconds: int.parse(verbParams[AtConstants.ttl]!));
    }
    switch (operation) {
      case 'get':
        if (!atConnection.getMetaData().isAuthenticated) {
          throw UnAuthenticatedException(
              'otp:get requires authenticated connection');
        }
        do {
          response.data = _generateOTP();
        }
        // If OTP generated do not have digits, generate again.
        while (RegExp(r'\d').hasMatch(response.data!) == false);
        _otpStore.set(
            response.data!,
            DateTime.now()
                .toUtc()
                .add(otpExpiryDuration)
                .millisecondsSinceEpoch);
        break;
      case 'validate':
        String? otp = verbParams['otp'];
        bool isValid = isValidOTP(otp);
        if (isValid) {
          response.data = 'valid';
          return;
        }
        response.data = 'invalid';
    }
  }

  static bool isValidOTP(String? otp) {
    if (otp == null) {
      return false;
    }
    int? otpExpiry = _otpStore.get(otp);
    // Remove the OTP from the OTPStore to prevent reuse of OTP.
    _otpStore.remove(otp);
    if (otpExpiry != null &&
        otpExpiry >= DateTime.now().toUtc().millisecondsSinceEpoch) {
      return true;
    }
    return false;
  }

  /// This function generates a UUID and converts it into a 6-character alpha-numeric string.
  ///
  /// The process involves converting the UUID to a hashcode, then transforming the hashcode
  /// into its Hexatridecimal representation to obtain the desired alpha-numeric characters.
  ///
  /// Additionally, if the resulting OTP contains "0" or "O", they are replaced with different
  /// number or alphabet, respectively. If the length of the OTP is less than 6, "padRight"
  /// is utilized to extend and match the length.
  String _generateOTP() {
    var uuid = Uuid().v4();
    Random random = Random();
    var otp = uuid.hashCode.toRadixString(36).toUpperCase();
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
    return otp;
  }

  String _generateRandomAlphabet() {
    int minAscii = 'A'.codeUnitAt(0); // ASCII value of 'A'
    int maxAscii = 'Z'.codeUnitAt(0); // ASCII value of 'Z'
    int randomAscii;
    do {
      randomAscii = minAscii + Random().nextInt((maxAscii - minAscii) + 1);
      // 79 is the ASCII value of "O". If randamAscii is 79, generate again.
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

  /// Retrieves the number of OTPs currently stored in the OTPStore.
  ///
  /// This method is intended for unit testing purposes to access the size of
  /// the OTPStore's internal store.
  @visibleForTesting
  int size() {
    // ignore: invalid_use_of_visible_for_testing_member
    return _otpStore.size();
  }
}
