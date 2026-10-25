Feature: A notification whose key is too long is never sent

  An atServer refuses a notify from its own client, to any atSign,
  its own included, whose key is longer than the recipient could hold:
  255 characters, counting the "cached:" prefix when the recipient will
  cache it (the notify has a ttr, or is a delete). The client is answered
  AT0016 and nothing is stored, queued or sent. Before it sends a queued
  notification to another atServer, the atServer checks the same length
  again; one that is too long, such as one queued before this check
  existed, is not sent: it is marked errored, reported as
  notification.error and logged at severe, and the notifications queued
  after it are sent without waiting behind it.

  Races: the client's notify is checked before anything is stored; the
  sending check runs before the first attempt to send each notification.
  Replay: a refused notify stores nothing; the client may send it again
  with a shorter key.
  DoS: each check is one length comparison, and a too-long queued
  notification no longer holds back the atSign's later notifications to
  that recipient.
  Forgery: unchanged.
  Impersonation: unchanged; the checks act for no atSign.

  Here <key256> stands for a key of 256 characters, and so on.

  Scenario: A client's notify whose key is longer than 255 characters is refused
    Given a client authenticated as @alice
    When it sends notify:update:<key256>:v
    Then the atServer answers error:AT0016 with "notification key length 256 is greater than 255 chars"
    And nothing is stored, queued or sent, and the connection stays open

  Scenario: A notify the recipient would cache is refused when its cached key would be too long
    Given a client authenticated as @alice
    When it sends notify:update:ttr:100000:ccd:true:<key250>:v to @bob
    Then the atServer answers error:AT0016 with "notification key length 257 is greater than 255 chars"
    And nothing is stored, queued or sent

  Scenario: Keys at the limit are accepted
    Given a client authenticated as @alice
    When it sends a notify to @bob whose key has 255 characters and no ttr, and one with a ttr whose key has 248 characters
    Then both are accepted and sent to @bob

  Scenario: A queued notification whose key is too long is not sent
    Given a notification to @bob whose key has 256 characters was queued before this check existed
    When the atServer's sender for @bob reaches it
    Then it is not sent, it is marked errored, and notification.error is reported
    And one severe line names its id and the key's length
    And @alice's later notifications to @bob are sent without waiting behind it
