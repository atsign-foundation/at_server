Feature: The atServer asks a client for a certificate unless its ClientHello offers only http/1.1

  The atServer's TLS port offers two protocols by ALPN: atProtocol/1.0 and
  http/1.1. It reads the first TLS record of each connection, the ClientHello,
  before the handshake. When the ALPN offer contains http/1.1 and does not
  contain atProtocol/1.0, the atServer does not send a CertificateRequest, and
  the connection is served over HTTP, including the /ws WebSocket path. A
  browser's wss connection is this case. Every other connection is sent a
  CertificateRequest, as every connection is today: no ALPN, atProtocol/1.0,
  both protocols, a ClientHello it cannot parse, a first record over 16 KiB, a
  ClientHello that spans more than one TLS record, a first byte that is not a
  handshake record, and a connection that sends no complete record within
  5 seconds. A ClientHello split across several reads is reassembled and
  decided as one.

  A connection that was not sent a CertificateRequest reaches only the HTTP
  and /ws paths. If it negotiated anything other than http/1.1, the atServer
  closes it before any verb runs. On a /ws connection the atServer accepts a
  from: for its own atSign, which PKAM, APKAM or CRAM then authenticates. It
  refuses a from: for any other atSign, because that connection has no TLS peer
  certificate to check. On the Atsign Protocol path a from: for another atSign
  is checked against the peer's certificate, as today.

  At most 64 sockets wait in the peek phase at once. A socket that arrives
  when 64 are waiting skips the peek and is handshaken with the
  CertificateRequest. The atServer never closes a socket because of that
  limit.

  Races: each connection's decision is made from its own first record and
  shared with no other connection. The atServer reads nothing from the socket
  between the peek and the handshake; the bytes it read are handed to the
  handshake. A certificate reload takes effect for the next connection, which
  reads the current certificate chain.
  Replay: nothing is stored or spent; a resent ClientHello is decided again
  from its own bytes.
  DoS: the peek holds a socket for at most 5 seconds and reads at most one
  16 KiB record. At most 64 sockets are in the peek phase; a further socket
  is handshaken with the request at once and is not held. A socket in the
  peek phase that reaches end of stream, errors, times out or finishes its
  handshake frees its slot. A handshake that fails closes its socket and
  never stops the listener.
  Forgery and impersonation: the decision to skip the request is made from
  the client's own offer, and a client can offer anything. Skipping it gives
  a connection nothing it did not have: it reaches only HTTP and /ws, where no
  certificate is read. A client that wants the Atsign Protocol path must be
  sent the request, because that path is reached only by a connection that was
  asked. A client that offers http/1.1 alone but negotiates something else is
  closed. The check of a peer's certificate on the Atsign Protocol path is
  unchanged.

  Scenario Outline: The CertificateRequest follows the ALPN offer
    Given the atServer is running with TLS
    When a client connects to its TLS port offering <offer>
    Then the atServer <asks> the client for a certificate
    And the negotiated protocol is <selected>

    Examples:
      | offer                    | asks           | selected       |
      | http/1.1                 | does not ask   | http/1.1       |
      | h2, http/1.1             | does not ask   | http/1.1       |
      | no ALPN                  | asks           | none           |
      | atProtocol/1.0           | asks           | atProtocol/1.0 |
      | atProtocol/1.0, http/1.1 | asks           | atProtocol/1.0 |
      | http/1.1, atProtocol/1.0 | asks           | atProtocol/1.0 |

  Scenario: A browser opens /ws without being asked for a certificate
    Given the atServer is running with TLS
    When a client offering only http/1.1 opens wss://host:port/ws
    Then the atServer sends no CertificateRequest
    And the client reads the @ prompt

  Scenario: A forced HelloRetryRequest does not change the decision
    Given the atServer is running with TLS
    When a client offering only http/1.1 sends a ClientHello whose key share the atServer rejects, and then a second ClientHello
    Then the atServer sends no CertificateRequest
    And the negotiated protocol is http/1.1

  Scenario Outline: A ClientHello split across reads is decided as a whole
    Given the atServer is running with TLS
    When a client offering only http/1.1 sends its ClientHello in <reads> reads, with a 1.5 KB key share
    Then the atServer sends no CertificateRequest
    And the connection is served over HTTP

    Examples:
      | reads |
      | 1     |
      | 2     |
      | 3     |

  Scenario Outline: A ClientHello the atServer cannot decide on gets the CertificateRequest
    Given the atServer is running with TLS
    When a client connects and <sends>
    Then the atServer asks the client for a certificate
    And the client sees a CertificateRequest and can complete the handshake

    Examples:
      | sends                                                |
      | a ClientHello whose extensions do not parse          |
      | a first TLS record longer than 16 KiB                |
      | a ClientHello that spans more than one TLS record    |
      | a first byte that is not a handshake record          |
      | random bytes                                         |
      | half of a ClientHello and then nothing for 5 seconds |

  Scenario Outline: A connection that ends before a complete first record is closed and frees its slot
    Given the atServer is running with TLS
    When a client <ends>
    Then the atServer closes the socket
    And a client that then connects offering only http/1.1 opens wss://host:port/ws without a CertificateRequest

    Examples:
      | ends                                                   |
      | closes the connection before sending a byte            |
      | closes the connection partway through its ClientHello  |
      | resets the connection partway through its ClientHello  |

  Scenario: A handshake that fails after the peek closes the socket and frees its slot
    Given the atServer is running with TLS
    When a client sends a complete ClientHello and then fails the handshake
    Then the atServer closes the socket
    And a client that then connects offering only http/1.1 opens wss://host:port/ws without a CertificateRequest

  Scenario Outline: A connection that was not asked for a certificate and negotiated another protocol is closed
    Given a connection to which the atServer sent no CertificateRequest
    When its negotiated protocol is <selected>
    Then the atServer closes it before any verb runs
    And it is not handed to the HTTP handler

    Examples:
      | selected       |
      | none           |
      | atProtocol/1.0 |

  Scenario: An unasked connection that negotiated http/1.1 is handed to the HTTP handler
    Given a connection to which the atServer sent no CertificateRequest
    When its negotiated protocol is http/1.1
    Then it is handed to the HTTP handler

  Scenario: A browser-ALPN connection's Atsign Protocol bytes never reach the verb handler
    Given a connection offering only http/1.1, to which the atServer sent no CertificateRequest
    When it sends the line from:@alice as raw bytes instead of an HTTP request
    Then no verb runs
    And the atServer closes the connection

  Scenario Outline: HTTP other than GET on a connection that was not asked for a certificate
    Given a connection offering only http/1.1, to which the atServer sent no CertificateRequest
    When it sends <method> /@alice
    Then it is answered 405

    Examples:
      | method |
      | POST   |
      | PUT    |
      | DELETE |

  Scenario: A client signs in to the atServer's own atSign over /ws
    Given @alice's atServer and a /ws connection that was not asked for a certificate
    When it sends from:@alice and then pkam: with a valid signature for @alice
    Then the atServer answers the from: with a challenge
    And the atServer authenticates the connection as @alice

  Scenario: A client cannot send a from: for another atSign over /ws
    Given a /ws connection that was not asked for a certificate
    When it sends from:@bob on @alice's atServer
    Then the atServer answers the from: with an error, not a challenge
    And a from:@alice sent next on the same connection is answered with a challenge
    And the connection is not marked as from @bob
    And the atServer keeps running

  Scenario Outline: A from: for another atSign on the Atsign Protocol path is checked against the peer's certificate
    Given @bob's atServer connects to @alice's atServer, which asks it for a certificate
    When it sends from:@bob after presenting <certificate>
    Then the atServer <answer>

    Examples:
      | certificate                                          | answer                                         |
      | a certificate for the host the root returns for @bob | answers with a challenge                       |
      | no certificate                                       | answers Certificate Verification Failed        |
      | a certificate for another host                       | answers Certificate Verification Failed        |

  Scenario Outline: The pre-handshake limit never closes a socket
    Given 64 sockets are waiting in the peek phase
    When the next socket connects offering <offer>
    Then it skips the peek
    And the atServer handshakes it, and sends it a CertificateRequest
    And the atServer does not close it because of the limit

    Examples:
      | offer          |
      | http/1.1       |
      | atProtocol/1.0 |
      | no ALPN        |

  Scenario Outline: Slots in the peek phase are freed
    Given 64 sockets are waiting in the peek phase
    When <event> for one of them
    Then a client that then connects offering only http/1.1 is sent no CertificateRequest

    Examples:
      | event                                |
      | its 5-second peek timeout passes     |
      | the client ends the connection       |
      | its handshake starts                 |

  Scenario: A certificate reload applies to the next connection
    Given the atServer is running with TLS
    When its certificate is replaced and the atServer restarts its listener
    Then a /ws connection and a from: for another atSign on the Atsign Protocol path both see the new certificate chain
