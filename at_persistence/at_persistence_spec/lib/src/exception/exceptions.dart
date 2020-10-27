/// An exception that provides information on a data store access or error thrown by data stores.
/// Each DataStoreException provides the following information:
/// A string describing the error, available via the method getMesasge.
/// An integer error code that is specific to a data store. This is the actual error code returned by the underlying data store.
/// And a Instance of actual exception returned by the data store.
class DataStoreException implements Exception {
  String message;
  int vendorErrorCode;
  Exception vendorException;

  DataStoreException(this.message,
      {this.vendorErrorCode, this.vendorException});

  ///Returns the cause of the exception
  ///@return String : Returns the exception cause.
  @override
  String toString() {
    return message;
  }
}
