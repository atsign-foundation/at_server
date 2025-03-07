abstract class AtConnection<T> {
  /// The underlying connection
  T get underlying;

  /// Gets the connection metadata
  AtConnectionMetaData get metaData;

  /// Write some [data] to the [underlying] connection,
  /// and call underlying.flush or equivalent to ensure that
  /// exceptions can be thrown directly to the calling code
  Future<void> write(String data);

  /// closes the underlying connection
  Future<void> close();

  /// Returns true if connection is closed or idle for configured time
  bool isInValid();
}

abstract class AtConnectionMetaData {
  static const String clientVersionNotAvailable = 'n/a';

  String? sessionID;
  DateTime? lastAccessed;
  DateTime? created;
  bool isClosed = false;
  bool isCreated = false;
  bool isStale = false;
  bool isListening = false;

  bool _isAuthenticated = false;

  /// Authenticated via CRAM, PKAM, APKAM
  bool get isAuthenticated => _isAuthenticated;

  /// Was authenticated via CRAM, PKAM, APKAM
  set isAuthenticated(bool b) {
    _isAuthenticated = b;
    if (_isAuthenticated) {
      // if isAuthenticated is set to true, isPolAuthenticated must be false
      _isPolAuthenticated = false;
    }
  }

  bool _isPolAuthenticated = false;

  /// Authenticated as another atSign
  bool get isPolAuthenticated => _isPolAuthenticated;

  /// Authenticated as another atSign
  set isPolAuthenticated(bool b) {
    _isPolAuthenticated = b;
    if (_isPolAuthenticated) {
      // if isPolAuthenticated is set to true, isAuthenticated must be false
      _isAuthenticated = false;
    }
  }

  bool isStream = false;
  String? streamId;
  //// if [isAuthenticated] is true, then authType is set to cram/legacy_pkam/apkam
  AuthType? authType;

  /// Represents the version of the client initiated the connection.
  /// Defaults to 'n/a' - i.e. 'not available'
  String clientVersion = clientVersionNotAvailable;
}

enum AuthType { cram, pkamLegacy, apkam }
