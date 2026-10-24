Feature: A connection has at most one monitor feed

  Each connection that runs monitor has exactly one feed of live
  notifications. A later monitor on the same connection replaces the
  earlier feed: the latest regex and selfNotifications flag apply, and
  pushes the earlier feed had already queued go out first, once. The feed
  ends when the connection closes. Live notifications reach a connection
  in the order the atServer queued them. With an epoch, monitor first
  writes the stored notifications after that epoch whose key matches the
  regex (sender is not matched, as today), then the live pushes queued
  meanwhile, each notification once. Live pushes still match the key or
  the sender, as today. Every push is checked against the enrollment the
  connection stands on at the moment it is written. A push the feed
  decides not to write logs a warning naming the notification's id and key
  and the connection's session and enrollment. A feed that ends with
  pushes still queued logs one warning counting those it would have
  written, and a write that fails logs at severe, naming the id and key.

  Races: the fan-out takes its list of feeds synchronously when a
  notification is queued, so each notification goes to each connection's
  one feed once. A replacing feed waits for the replaced feed's queued
  pushes before it writes. A close removes the feed one microtask after
  the connection is marked closed; a push in that window finds the
  connection invalid and is dropped with a warning. Commands on one
  connection run one at a time.
  Replay: replay is from the store, filtered and authorized per
  notification for the enrollment the connection stands on when written;
  a re-sent monitor:<epoch> replays from that epoch, as today. Nothing is
  keyed by notification id alone: replay's de-duplication keys on the
  sender and the id together.
  DoS: one feed per connection, so a client that runs monitor K times
  costs one feed, not K subscriptions that outlive the connection.
  Outside a replay the regex is matched in the feed's own turn, after the
  call that queued the notification has returned, so queueing never waits
  on a regex. During a replay it is matched when the notification is
  queued, so a push the feed would not write is not held. A costly regex
  holds the atServer's isolate while it runs, either way. The replay
  de-duplication set holds at most the backlog and is dropped once the
  pushes queued during replay have been written. The pushes held during
  a replay count toward the unsent bytes bound with the bytes waiting to
  be sent, so a client that stops reading mid-replay is closed at the
  limit.
  Forgery: a warning names the key through the existing log sanitiser,
  so a peer-chosen key cannot start a new log record.
  Impersonation: a feed exists only on an authenticated connection, and
  every write is authorized for the enrollment the connection stands on
  when it is written, never for the one it stood on when monitor ran.

  Scenario: A second monitor on a connection replaces the first
    Given @alice's authenticated client has run monitor on a connection
    When it runs monitor again on the same connection
    And @bob's atServer delivers one notification
    Then the connection is written that notification once

  Scenario: The latest monitor's selfNotifications flag applies
    Given @alice's authenticated client has run monitor:selfNotifications on a connection
    When it runs monitor on the same connection
    And a self notification is queued
    Then the connection is not written the self notification

  Scenario: Pushes queued before a replacing monitor go out first, once
    Given a connection whose monitor feed is still writing notification n1
    When the client runs monitor again on that connection
    And notification n2 is queued
    Then the connection is written n1 and then n2, each once

  Scenario: A monitor with an invalid regex leaves the existing feed as it was
    Given a connection running monitor with regex wavi
    When it runs monitor with regex [
    Then it is refused with AT0003: Invalid regex: [
    And a later notification for phone.wavi is still written to it

  Scenario: Closing the connection ends its feed
    Given a connection running monitor
    When the connection closes
    Then the atServer holds no feed for it, without waiting for another notification

  Scenario: Live pushes reach a connection in the order they were queued
    Given a connection running monitor, whose enrollment lookup for n1 is slower than for n2
    When n1 and then n2 are queued
    Then the connection is written n1 and then n2

  Scenario: Replay is written before live pushes, each notification once
    Given notification n1 is stored after epoch t
    And a client runs monitor:<t> on a connection
    When notification n2 is stored and queued while the replay is reading the store
    Then the connection is written n1 and then n2, each once

  Scenario: Replay matches the key only and live delivery matches the key or the sender
    Given a stored notification from @bob for key phone.buzz after epoch t
    When a client runs monitor:<t> with regex ^bob, which the sender bob matches and the key @alice:phone.buzz@bob does not
    Then the stored notification is not replayed
    And a live notification from @bob for key phone.buzz is written

  Scenario: A replay that fails leaves no feed behind
    Given reading the notification store fails
    When a client runs monitor:<t>
    Then monitor is refused with the store's error
    And later notifications are not written to that connection

  Scenario: A notification the client did not ask for causes no enrollment lookup
    Given a connection running monitor with regex wavi as an enrollment holding only buzz
    When a notification for phone.other is queued
    Then no enrollment lookup is made and no warning is logged

  Scenario: A push the connection's enrollment may not read is logged and not written
    Given a connection running monitor as an enrollment holding only buzz
    When a notification for phone.wavi is queued
    Then the connection is not written it
    And a warning names the notification's id and key, the session and the enrollment, and says it is not authorized

  Scenario: A push after the client re-authenticates is checked against the new enrollment
    Given a connection that ran monitor as enrollment e1, which holds wavi
    And it has since authenticated with pkam as enrollment e2, which holds only buzz
    When a notification for phone.wavi is queued
    Then the connection is not written it

  Scenario: A push to a connection whose re-authentication failed is logged and not written
    Given a connection that ran monitor as enrollment e1, which holds wavi
    And a later pkam on it failed
    When a notification for phone.wavi is queued
    Then the connection is not written it
    And a warning names the notification's id and key, the session and the enrollment, and says the connection is not authenticated

  Scenario: Stats notifications still reach a monitor connection
    Given a connection running monitor
    When a key is updated
    Then the connection is written a statsNotification, whatever its regex
