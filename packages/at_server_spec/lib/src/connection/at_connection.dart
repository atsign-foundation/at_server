import 'dart:io';

abstract class AtConnection {
  /// Write a data to the underlying socket of the connection
  /// @param - data - Data to write to the socket
  /// @throws [AtIOException] for any exception during the operation
  void write(String data);

  /// Retrieves the socket of underlying connection
  Socket getSocket();

  /// Gets the connection metadata
  AtConnectionMetaData getMetaData();

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
  bool isAuthenticated = false;
  bool isPolAuthenticated = false;
  bool isStream = false;
  String? streamId;
  //// if [isAuthenticated] is true, then authType is set to cram/legacy_pkam/apkam
  AuthType? authType;

  /// Represents the version of the client initiated the connection.
  /// Defaults to 'n/a' - i.e. 'not available'
  String clientVersion = clientVersionNotAvailable;
}

enum AuthType { cram, pkamLegacy, apkam }
