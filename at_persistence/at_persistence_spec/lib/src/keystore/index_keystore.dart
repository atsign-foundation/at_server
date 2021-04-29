import 'package:at_persistence_spec/at_persistence_spec.dart';

/// IndexKeyStore represents a keystore that can index values and search through those values
abstract class IndexKeyStore<K, V, T>
    implements SecondaryKeyStore<K, V, T> {

  /// Searches all the values in keystore with queryWords.
  /// @param keywords - query words to search
  /// @param index - defines the scope of the search
  /// @returns list of values that match the keywords
  Future<List<String>> search(List<String> keywords, {String index, int fuzziness, bool contains});

  /// Indexes the data in the keystore for future searches.
  /// @param data - data to be indexed
  /// @param id - id for this data. If not specified, a UUID will be generated and used
  /// @param index - the index that this data should be associated with
  /// @returns the id of the data
  Future<String> index(String data, {String id, String index});
}
