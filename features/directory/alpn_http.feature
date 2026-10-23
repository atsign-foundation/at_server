Feature: The atDirectory answers HTTP on its Atsign Protocol port to a client that negotiates it

  The atDirectory's TLS port, 64 by default, offers two protocols by ALPN:
  atProtocol/1.0 and http/1.1. A client that negotiates http/1.1 is answered
  by the same HTTP handler as the HTTPS port, 443 by default. A client that
  negotiates atProtocol/1.0, offers no ALPN, or offers only protocols the
  atDirectory does not speak, speaks the Atsign Protocol, as every client
  does today. An atDirectory run without TLS speaks only the Atsign Protocol
  on its port.

  On either port an HTTP connection carries one request. The atDirectory
  answers it with Connection: close and then closes the connection, whatever
  the client asked for; it does not answer a second request sent on that
  connection. Once its TLS handshake has completed, a connection that sends
  no complete request is closed within 10 seconds, by a 5-second idle
  timeout that is checked every 5 seconds.
  A request for a path below an atSign is redirected to that atSign's
  atServer with the whole path, the atSign first, as the atServer expects.
  Every HTTP answer carries Access-Control-Allow-Origin: *, so a web app on
  any origin can read it.

  Races: each connection's protocol is fixed by its own TLS handshake, and
  connections share nothing beyond the directory they read.
  Replay: nothing is authenticated or stored, so a resent request gets the
  same answer.
  DoS: a URI over 1000 characters, or one that does not decode, is answered
  400; once its TLS handshake has completed, a connection is held for at most
  one request, or for 10 seconds when it sends none; and each lookup takes a
  connection of its own. Like the HTTPS port today, HTTP does not slow
  repeated lookups of atSigns the directory does not hold, as an Atsign
  Protocol connection does.
  Forgery and impersonation: either protocol returns the directory's own
  record for an atSign; TLS authenticates the atDirectory, and neither
  protocol authenticates the client, as today. The records are public, and
  no answer depends on a cookie or other credential, so any origin may read
  them.

  Scenario Outline: A client that does not negotiate http/1.1 speaks the Atsign Protocol
    Given the atDirectory holds @alice at alice.example:6464
    When a client connects to its TLS port offering <offer> and sends alice
    Then no protocol other than <selected> is negotiated
    And it is answered alice.example:6464

    Examples:
      | offer                    | selected       |
      | no ALPN                  | none           |
      | atProtocol/1.0           | atProtocol/1.0 |
      | atProtocol/1.0, http/1.1 | atProtocol/1.0 |
      | h2                       | none           |

  Scenario Outline: A client that negotiates http/1.1 is answered over HTTP
    Given the atDirectory holds @alice at alice.example:6464
    When a client connects to its TLS port offering <offer> and sends GET <path>
    Then it is answered <answer>

    Examples:
      | offer        | path                      | answer                                                 |
      | http/1.1     | /@alice                   | 200 with body alice.example:6464                       |
      | h2, http/1.1 | /@alice                   | 200 with body alice.example:6464                       |
      | http/1.1     | /@alice/x/y?z=1           | 302 to https://alice.example:6464/@alice/x/y?z=1       |
      | http/1.1     | /@alice/a%0D%0A%3F%23     | 302 to https://alice.example:6464/@alice/a%0D%0A%3F%23 |
      | http/1.1     | /@nobody                  | 404                                                    |
      | http/1.1     | /@                        | 404                                                    |
      | http/1.1     | /@a!b                     | 404                                                    |
      | http/1.1     | /@alice/                  | 200 with body alice.example:6464                       |
      | http/1.1     | /%ff                      | 400                                                    |
      | http/1.1     | a path of 1001 characters | 400                                                    |

  Scenario Outline: Any origin may read an HTTP answer
    Given the atDirectory holds @alice at alice.example:6464
    When a client on <port> sends <method> <path> with Origin: https://finder.example
    Then the answer, <status>, carries Access-Control-Allow-Origin: *

    Examples:
      | port                               | method | path     | status |
      | its TLS port, negotiating http/1.1 | GET    | /@alice  | 200    |
      | its TLS port, negotiating http/1.1 | GET    | /@nobody | 404    |
      | its HTTPS port                     | GET    | /@alice  | 200    |
      | its HTTPS port                     | POST   | /@alice  | 401    |

  Scenario Outline: An HTTP connection is closed once its response is sent
    Given the atDirectory holds @alice at alice.example:6464
    When a client connects to <port>, asks for keep-alive, and sends GET /@alice and then GET /@alice again on the same connection
    Then it is answered 200 with body alice.example:6464 and Connection: close, once
    And the atDirectory closes the connection

    Examples:
      | port                               |
      | its TLS port, negotiating http/1.1 |
      | its HTTPS port                     |

  Scenario Outline: An HTTP connection that sends no complete request is closed within 10 seconds
    Given an HTTP connection to <port>
    When it sends <sent> and then nothing more
    Then the atDirectory closes it within 10 seconds, without an answer

    Examples:
      | port                               | sent                       |
      | its TLS port, negotiating http/1.1 | nothing                    |
      | its TLS port, negotiating http/1.1 | half of a request's header |
      | its HTTPS port                     | nothing                    |

  Scenario: An HTTP request the atDirectory cannot answer is answered 500
    Given the atDirectory cannot read its records
    When a client on its TLS port, negotiating http/1.1, sends GET /@alice
    Then it is answered 500, with Connection: close

  Scenario Outline: The atDirectory keeps answering when a connection fails
    Given the atDirectory holds @alice at alice.example:6464
    When a client on <port> <fails>
    Then the atDirectory keeps running
    And a client that then sends GET /@alice over HTTP to <port> is answered 200

    Examples:
      | port           | fails                                                         |
      | its HTTPS port | resets the connection before sending anything                 |
      | its HTTPS port | resets the connection partway through its TLS hello           |
      | its TLS port   | resets the connection before sending anything                 |
      | its HTTPS port | sends GET /@alice and resets the connection before its answer |

  Scenario: The HTTPS port answers HTTP whatever ALPN the client offers
    Given the atDirectory holds @alice at alice.example:6464
    When a client connects to the HTTPS port, offering any ALPN or none, and sends GET /@alice
    Then no ALPN protocol is negotiated
    And it is answered 200 with body alice.example:6464

  Scenario: An atDirectory run without TLS speaks only the Atsign Protocol
    Given the atDirectory runs without TLS and holds @alice at alice.example:6464
    When a client connects to its port and sends alice
    Then it is answered alice.example:6464
