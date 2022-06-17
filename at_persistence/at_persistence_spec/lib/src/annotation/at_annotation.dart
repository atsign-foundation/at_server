///Class for at_server custom annotation.
///Methods that are used by at_secondary_server are marked with this annotation.
class AtServerAnnotation {
  const AtServerAnnotation();
}

///Class for at_client annotation.
///Methods that are used by at_client/at_client_mobile are marked with this annotation.
class AtClientAnnotation {
  const AtClientAnnotation();
}

///use @server to mark methods exclusively used by at_secondary_server
const AtServerAnnotation server = AtServerAnnotation();

///use @server to mark methods exclusively used by at_client
const AtClientAnnotation client = AtClientAnnotation();
