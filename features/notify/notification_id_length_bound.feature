Feature: A notification id has at most 36 characters

  An atServer refuses a notify whose id: is longer than 36 characters,
  whether its own client or another atServer sends it. It answers AT0003
  with "notification id must have at most 36 characters" before it
  stores, queues, pushes or reports anything. An authenticated client,
  or a peer that has proved itself by pol, keeps its connection. An id of
  exactly 36 characters, the length of the UUID every known client sends,
  is accepted. A notify with no id: is unchanged: the atServer gives it a
  UUID. A connection that has not authenticated is answered as it is today,
  whatever the id.

  Races: the check reads only the request, before the notify mutex's
  critical work stores anything.
  Replay: nothing is stored or queued for a refused notification, so
  nothing about it is retried after a restart. A sending atServer that
  gets AT0003 retries the notification until it expires, as it does for
  every other refusal, and holds back its later notifications to this
  atSign until then. A notification expires 15 minutes after the sending
  atServer accepted it by default, or once the ttln its client set has
  passed, at most 8 days.
  DoS: the check measures one ASCII string (the notify syntax allows only
  [A-Za-z0-9_-] in an id). The answer does not repeat the id.
  Forgery: the id is the only notification attribute the sender alone
  chooses that reaches telemetry; with it bounded, every attribute of
  every notification event is bounded, for notifications accepted since
  the bound. One stored before it, and sent once the atServer restarts,
  keeps the id it was given.
  Impersonation: unchanged; the check runs after authentication is
  established and acts for no atSign.

  Here <id36> stands for an id of 36 characters and <id37> for one of 37.

  Scenario: A client's notify whose id has more than 36 characters is refused
    Given @alice's authenticated client
    When it sends notify:id:<id37>:update:@bob:phone.wavi@alice:v
    Then it is refused with AT0003: notification id must have at most 36 characters
    And nothing is stored or queued for @bob
    And the connection stays open

  Scenario: A peer's notify whose id has more than 36 characters is refused
    Given a peer that has proved itself as @bob by pol
    When it sends notify:id:<id37>:update:messageType:key:ttln:60000:@alice:phone.wavi@bob:v
    Then the atServer answers error:AT0003-Exception: notification id must have at most 36 characters, then the prompt @
    And nothing is stored, no monitor is pushed it, and no notification.received is sent
    And the connection stays open

  Scenario Outline: A notify whose id has exactly 36 characters is accepted
    Given <sender>
    When it sends a notify whose id is <id36>
    Then the notification is stored with id <id36>

    Examples:
      | sender                                       |
      | @alice's authenticated client                |
      | a peer that has proved itself as @bob by pol |

  Scenario: A connection that has not authenticated is answered as today whatever the id
    Given a connection that has not authenticated
    When it sends notify:id:<id37>:update:@bob:phone.wavi@alice:v
    Then it is refused as unauthenticated, as it is for any other notify
