abstract class AtKeyMetadataStore<String, M> {
  Future<void> put(String atKey, M metadata);

  Future<M?> get(String atKey);

  bool contains(String atKey);
}
