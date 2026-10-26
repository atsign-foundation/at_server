Feature: A connection that leaves too many bytes unsent is closed

  Every inbound connection writes through a queue that holds the bytes
  its transport has not yet taken. When a write arrives while bytes are
  already waiting, or held for a monitor's replay, and would take them
  above the limit (16 MiB by default, connection.inbound_max_unsent_bytes
  in config.yaml, which the atServer refuses to start with when it is
  below 1 MiB or not an integer), the atServer drops what is waiting,
  closes the connection and logs one warning naming the session, the
  enrollment (or CRAM, pol and the peer's atSign, or not authenticated)
  and the byte counts. A write onto an empty queue with nothing held is
  always taken, whatever its size, so one large notification or response
  never closes a connection by itself. A monitor's replay waits until the
  queue is empty before each notification, so a client that is reading
  never reaches the limit through replay. Stats notifications go through
  the same queue and count toward the limit.

  Races: the limit is checked synchronously in the write that would
  breach it; that write throws ConnectionInvalidException, and so does
  every later one, because the connection is closed. A WebSocket
  connection's socket is destroyed in that same close, as a TLS
  connection's is; no close frame is sent, since the client is not
  reading. A replay waiting for the queue to empty is released when the
  connection closes. The warning is logged once per connection. A
  transport that starts taking writes again is handed what is waiting
  within the same turn.
  Replay: nothing is stored or spent; a client resumes from its own
  watermark with monitor:<epoch>, and each replayed notification is
  authorized again for the enrollment the connection stands on.
  DoS: the limit covers the bytes waiting in the queue together with the
  live pushes a monitor's replay holds back, each counted as the line it
  would write; a push the feed's regex does not match is not held. So
  what an atServer holds for one connection is bounded by the limit plus
  one write or held push plus what the transport itself buffers, which
  the operating system bounds (measured on loopback: about 0.6 MB plain,
  WebSocket or TLS on macOS; about 2.6 MB plain, 2.7 MB WebSocket and
  4.3 MB TLS on Linux). The
  bound holds before authentication too, so a client that pipelines
  lookups of a large public value and never reads is closed. The
  connection logs one warning when it closes; whatever made the refused
  write (a command's response, a push or a stats notification) also logs
  its failure.
  Forgery: the warning carries only values this atServer assigned (the
  session id and enrollment id) or proved (the pol atSign).
  Impersonation: unchanged; the queue acts for no atSign.

  Scenario: A monitor connection whose client stops reading is closed at the limit
    Given a monitor connection as enrollment e1 whose client has stopped reading
    When notifications keep arriving until more than the limit is waiting to be sent
    Then the atServer closes the connection
    And it logs one warning naming the session, enrollment e1, the bytes waiting and the limit
    And the bytes that were waiting are dropped

  Scenario: A WebSocket connection closed at the limit releases its socket at once
    Given a WebSocket monitor connection whose client has stopped reading
    When notifications keep arriving until more than the limit is waiting to be sent
    Then the atServer closes the connection and destroys its socket at once, without waiting for the client to read
    And it logs one warning naming the session, the enrollment, the bytes waiting and the limit

  Scenario: A WebSocket client that closes its end is closed by the atServer
    Given a WebSocket connection that has been written to
    When the client sends a close frame and closes its socket
    Then the atServer closes the connection and its socket, and the connection leaves the pool

  Scenario: A client that reads slowly is not closed
    Given a monitor connection whose client reads, but slower than notifications arrive for a while
    When the bytes waiting stay under the limit
    Then the connection stays open and every notification is written

  Scenario Outline: A client that reads in bursts receives every byte written to it
    Given a <transport> connection whose client reads in bursts and pauses at random, sometimes for over a second
    When the atServer writes numbered lines of mixed sizes to it, staying under the limit
    Then the client receives every line once, in order and whole
    And whenever the connection's transport is taking writes, no bytes are left waiting to be sent
    And once the client has read everything, the connection is drained

    Examples:
      | transport |
      | TLS       |
      | WebSocket |

  Scenario: One write larger than the limit onto an empty queue is taken
    Given a monitor connection with nothing waiting to be sent
    When a notification whose line is larger than the limit is written
    Then the connection stays open and the line is sent once the client reads

  Scenario: Replay waits for the client instead of filling the queue
    Given a client that reads, with a backlog after epoch t larger than the limit
    When it runs monitor:<t>
    Then every stored notification is written and the connection stays open

  Scenario: A replay to a client that is not reading holds back its live pushes
    Given a client that runs monitor:<t> and stops reading
    When live notifications arrive during the stalled replay
    Then no more than one notification is waiting in the queue
    And only the live pushes its regex matches are held, counted toward the limit with the bytes waiting
    And once those pass the limit, the atServer closes the connection and logs one warning
    And otherwise the live pushes are written, after the replay, once the client reads

  Scenario Outline: The bytes held for a replay are released however the replay ends
    Given a client that runs monitor:<t> and has stopped reading
    And live notifications its regex matches are held behind the replay
    When <ending>
    Then the bytes held for the connection return to zero

    Examples:
      | ending                                                                                        |
      | the client closes the connection                                                              |
      | the client reads, and runs monitor again while the held notifications are still being written |
      | the client reads and the replay completes                                                     |

  Scenario: Stats notifications count toward the limit
    Given a monitor connection whose client has stopped reading, with bytes waiting close to the limit
    When a statsNotification is written that takes them above it
    Then the atServer closes the connection and logs the warning once

  Scenario: A client that sends commands and never reads the responses is closed at the limit
    Given a connection that has not authenticated and never reads
    When it pipelines lookups of a public key whose responses total more than the limit
    Then the atServer closes the connection and logs one warning saying it was not authenticated

  Scenario: What the client sees when it is closed
    Given a TLS monitor connection closed at the limit
    When the client reads again
    Then it reads the bytes its transport already held, possibly ending part way through a line, then end of stream

  Scenario: A client closed at the limit resumes from its watermark
    Given @alice's at_client monitor was closed at the limit after it had processed notifications up to epoch t
    When it reconnects
    Then it runs monitor:<t> and is written the notifications after t
