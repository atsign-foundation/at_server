abstract class AtServer {
  /// Starts the  server. Calling this method on an already started server has no effect.
  /// @throws [AtServerException] if the server cannot be started
  void start();

  /// Stops the server. Calling this method on an already stopped server has no effect.
  /// @throws [AtServerException] if the server cannot be stopped
  Future<void> stop();

  /// Returns status of the server
  /// @return true is the server is running.
  bool isRunning();

  /// Pauses the server. In this state the server would have been fully initialized but it will not serve any request till the resume is
  /// called.
  void pause();

  /// Resumes the server. In this state the server will be able to serve the request.
  void resume();
}

/// Class that holds server attributes
abstract class AtServerContext {}
