class ObjectsUtil {
  static bool anyNotNull(Set objs) {
    return objs.any((element) => element != null);
  }
}
