import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

/// A class for managing One-Time Passwords (OTPs) using a linked hash map.
///
/// This class allows you to store OTPs along with their expiration times and
/// periodically remove expired OTPs.
///
/// The [gcDuration] parameter determines the duration between each garbage
/// collection cycle. Expired OTPs are removed from the store during garbage
/// collection.
class OTPStore {
  /// The duration between each garbage collection. Default 60 minutes.
  final Duration gcDuration;

  /// The internal store for OTPs and their expiration times.
  final LinkedHashMap<String, int> _otpStore = LinkedHashMap();

  /// Creates an instance of the OTPStore class.
  ///
  /// The [gcDuration] parameter specifies the duration between each garbage
  /// collection cycle. During garbage collection, expired OTPs are removed
  /// from the store.
  ///
  /// By default, [gcDuration] is set to 60 minutes.
  OTPStore({this.gcDuration = const Duration(minutes: 60)}) {
    // Initialize a timer for periodic garbage collection.
    Timer.periodic(gcDuration, (Timer t) => _removeExpiredOTPs());
  }

  /// Retrieves the duration in millisecondsSinceEpoch associated with the given [key].
  ///
  /// Returns `null` if the [key] is not found in the OTP store
  int? get(String key) {
    return _otpStore[key];
  }

  /// Sets the OTP associated with the given [key] along with its expiration time.
  ///
  /// The [key] is typically the OTP value itself, and [expiryDurationSinceEpoch]
  /// represents the expiration time for the OTP as a duration since the epoch.
  void set(String key, int expiryDurationSinceEpoch) {
    _otpStore[key] = expiryDurationSinceEpoch;
  }

  /// Removes the OTP associated with the given [key] from the store.
  ///
  /// If the [key] is not found in the OTP store, this method has no effect.
  void remove(String key) {
    _otpStore.remove(key);
  }

  /// Removes expired OTPs from the store.
  ///
  /// This method is automatically called at regular intervals based on the
  /// [gcDuration] specified during object creation.
  void _removeExpiredOTPs() {
    _otpStore.removeWhere(
            (otp, expiryInMills) =>
        expiryInMills <= DateTime
            .now()
            .toUtc()
            .millisecondsSinceEpoch
    );
  }

  @visibleForTesting
  int size() {
    return _otpStore.length;
  }
}
