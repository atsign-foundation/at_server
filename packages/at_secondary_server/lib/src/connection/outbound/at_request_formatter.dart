class AtRequestFormatter {
  static String createFromRequest(String? atSign) {
    return 'from:$atSign\n';
  }

  static String createPolRequest() {
    return 'pol\n';
  }

  static String createLookUpRequest(String key) {
    return 'lookup:$key\n';
  }

  /// The cross-server `to:@toAtSign` verb — declares the target tenant to a peer
  /// atServer and, in one round trip, returns the peer's
  /// {publickey, signing_publickey} envelope. Sent as the first verb on the
  /// connection when [AtSecondaryConfig.crossServerToVerbEnabled] is on.
  static String createToRequest(String toAtSign) {
    return 'to:$toAtSign\n';
  }
}
