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
}
