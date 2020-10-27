class ObjectsUtil {
  /// Verifies if any of the named optional args are not null
  static bool isAnyNotNull(
      {dynamic a1,
      dynamic a2,
      dynamic a3,
      dynamic a4,
      dynamic a5,
      dynamic a6}) {
    return ((a1 != null) ||
            (a2 != null) ||
            (a3 != null) ||
            (a4 != null) ||
            (a5 != null)) ||
        (a6 != null);
  }

  /// Verifies if all of the named optional args are not null. Initializing to initial value of '@'
  static bool isNotNull(
      {dynamic a1 = '@',
      dynamic a2 = '@',
      dynamic a3 = '@',
      dynamic a4 = '@',
      dynamic a5 = '@',
      dynamic a6 = '@'}) {
    return ((a1 != null) &&
        (a2 != null) &&
        (a3 != null) &&
        (a4 != null) &&
        (a5 != null) &&
        (a6 != null));
  }
}
