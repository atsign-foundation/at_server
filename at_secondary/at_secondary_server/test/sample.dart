void main() {
  try {
    var clientSocket;
    clientSocket.socketConnection();
  } on Error catch (e) {
    print(e.toString());
  }
}
