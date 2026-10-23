Feature: The atServer bounds the HTTP connections it holds

  An atServer's TLS port offers atProtocol/1.0 and http/1.1 by ALPN. A
  client that negotiates http/1.1 is answered by the atServer's HTTP
  handler, which serves its public records to GET requests. An HTTP
  connection may carry several requests. Once its TLS handshake has
  completed, a connection with no request in progress is closed within 10
  seconds, by a 5-second idle timeout that is checked every 5 seconds, and
  an answer not fully sent within 30 seconds of its request, as when the
  client reads none of it, closes its connection. At most 50 HTTP
  connections are held at once by default, a bound that
  connection.http_max_limit sets at startup, and 0 or less holds none; a
  connection beyond it is closed without an answer, and the Atsign Protocol
  connections, bounded by connection.inbound_max_limit, are not affected. A
  connection upgraded to a WebSocket at /ws leaves those bounds and is held
  as an Atsign Protocol connection. An error the HTTP server raises closes
  at most the connection it concerns, and never stops the atServer. A soft
  restart closes the HTTP connections the atServer held.

  Races: each connection's protocol is fixed by its own TLS handshake, and
  the count of HTTP connections changes only on the atServer's event loop,
  as a connection is handed over and as it closes or upgrades.
  Replay: HTTP serves only public records and authenticates nothing, so a
  resent request gets the same answer.
  DoS: once its TLS handshake has completed, an idle or incomplete HTTP
  connection is held for at most 10 seconds, one whose answer is not sent
  within 30 seconds is closed, and at most connection.http_max_limit (50 by
  default) are held at once; a URI over 1000 characters, or one that does
  not decode, is answered 400.
  Forgery and impersonation: unchanged. TLS authenticates the atServer, and
  HTTP authenticates no client and serves only public records.

  Background:
    Given @alice's atServer holds public:hello@alice with value hello

  Scenario: An HTTP connection carries a further request
    When a client that negotiated http/1.1 sends GET /hello twice on one connection
    Then both are answered 200 with body hello

  Scenario: An idle HTTP connection is closed within 10 seconds
    Given a client that negotiated http/1.1 has been answered
    When it sends nothing more
    Then the atServer closes the connection within 10 seconds

  Scenario: An HTTP connection that sends no complete request is closed within 10 seconds
    Given a client has negotiated http/1.1
    When it sends part of a request and then nothing
    Then the atServer closes the connection within 10 seconds

  Scenario: An HTTP connection beyond the limit is closed without an answer
    Given @alice's atServer holds 50 HTTP connections
    When another client negotiates http/1.1
    Then the atServer closes that connection without answering it
    And the connections it already holds are still answered
    And a client that negotiates atProtocol/1.0 is still served

  Scenario: An atServer whose http_max_limit is 0 holds no HTTP connection
    Given @alice's atServer is configured with connection.http_max_limit 0
    When a client negotiates http/1.1
    Then the atServer closes that connection without answering it
    And a client that negotiates atProtocol/1.0 is still served

  Scenario: An HTTP connection whose answer is not sent within 30 seconds is closed
    Given a client that negotiated http/1.1 reads nothing the atServer sends
    When it sends requests whose answers are more than the connection can hold
    Then the atServer closes the connection within 30 seconds of the request whose answer it could not send

  Scenario: A WebSocket at /ws is not closed by the HTTP idle timeout or answer deadline
    Given a client that negotiated http/1.1 has upgraded to a WebSocket at /ws
    When it sends nothing for 40 seconds
    Then its connection is still open

  Scenario: A soft restart closes the HTTP connections the atServer held
    Given a client that negotiated http/1.1 keeps its connection busy with GET requests
    When the atServer soft restarts
    Then that connection is closed
    And a new connection that negotiates http/1.1 is answered

  Scenario: An HTTP request whose path does not decode is answered 400
    When a client that negotiated http/1.1 sends GET /%ff
    Then it is answered 400

  Scenario: An HTTP request the atServer cannot answer is answered 500
    Given the atServer fails unexpectedly while answering GET /hello
    When a client that negotiated http/1.1 sends GET /hello
    Then it is answered 500

  Scenario: An error the HTTP server raises does not stop the atServer
    Given the atServer's HTTP server has raised an error that is not a SocketException while taking a connection
    When a client that negotiated http/1.1 then sends GET /hello
    Then it is answered 200 with body hello
    And a client that negotiates atProtocol/1.0 is still served
