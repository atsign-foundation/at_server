Feature: A connection that leaves too many bytes unsent is closed

  Every inbound connection writes through a queue that holds the bytes
  its transport has not yet taken. When a write arrives while bytes are
  already waiting and would take them above the limit (16 MiB by
  default, connection.inbound_max_unsent_bytes in config.yaml), the
  atServer drops what is waiting, closes the connection and logs one
  warning naming the session, the enrollment (or CRAM, pol and the
  peer's atSign, or not authenticated) and the byte counts. A write onto
  an empty queue is always taken, whatever its size, so one large
  notification or response never closes a connection by itself. A
  monitor's replay waits until the queue is empty before each
  notification, so a client that is reading never reaches the limit
  through replay. Stats notifications go through the same queue and
  count toward the limit.

  Races: the limit is checked synchronously in the write that would
  breach it; that write throws ConnectionInvalidException, and so does
  every later one, because the connection is closed. A replay waiting
  for the queue to empty is released when the connection closes. The
  warning is logged once per connection.
  Replay: nothing is stored or spent; a client resumes from its own
  watermark with monitor:<epoch>, and each replayed notification is
  authorized again for the enrollment the connection stands on.
  DoS: what an atServer holds for one connection is bounded by the limit
  plus one write plus what the transport itself buffers (about 0.55 MB
  plain or WebSocket, 5.1 MB TLS, measured on loopback). The bound holds
  before authentication too, so a client that pipelines lookups of a
  large public value and never reads is closed. The connection logs one
  warning when it closes; whatever made the refused write (a command's
  response, a push or a stats notification) also logs its failure.
  Forgery: the warning carries only values this atServer assigned (the
  session id and enrollment id) or proved (the pol atSign).
  Impersonation: unchanged; the queue acts for no atSign.

  Scenario: A monitor connection whose client stops reading is closed at the limit
    Given a monitor connection as enrollment e1 whose client has stopped reading
    When notifications keep arriving until more than the limit is waiting to be sent
    Then the atServer closes the connection
    And it logs one warning naming the session, enrollment e1, the bytes waiting and the limit
    And the bytes that were waiting are dropped

  Scenario: A client that reads slowly is not closed
    Given a monitor connection whose client reads, but slower than notifications arrive for a while
    When the bytes waiting stay under the limit
    Then the connection stays open and every notification is written

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
    And the live pushes are written, after the replay, once the client reads

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
