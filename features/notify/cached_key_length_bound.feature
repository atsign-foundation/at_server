Feature: A notification whose cached key would be too long is refused before it is stored

  When another atServer delivers a notification that this atServer will
  cache, because it has a ttr or is a delete, this atServer checks the
  length of the cached key (cached: followed by the notification's key)
  before it stores anything. One whose cached key would be longer than
  255 characters is answered AT0016 with "notification key length N is
  greater than 255 chars", and nothing is stored, pushed to a monitor or
  reported. The peer keeps its connection.

  Races: the check reads only the request, inside the notify mutex and
  before the notification is stored, so no monitor is pushed a
  notification that is then refused.
  Replay: nothing is stored for a refused notification, so a retry of it
  is refused the same way rather than answered data:success as a
  notification already held. A sending atServer retries the notification
  until it expires, as it does for every other refusal, and holds back
  its later notifications to this atSign until then: 15 minutes by
  default, and at most 8 days when its client set ttln.
  DoS: the check is one length comparison on the request, and the answer
  names only the length, not the key.
  Forgery: unchanged; the notification's sender is the atSign that
  passed pol.
  Impersonation: unchanged; the check acts for no atSign.

  Here <key234> stands for a key segment of 234 characters, which makes a
  cached key of 257.

  Scenario: A peer's notification whose cached key would be too long is refused, and its sender holds back behind it
    Given a peer that has proved itself as @bob by pol
    When it sends notify:id:n1:update:messageType:key:ttr:100000:ccd:true:@alice:<key234>.wavi@bob:v
    Then the atServer answers error:AT0016-Exception: notification key length 257 is greater than 255 chars, then the prompt @
    And nothing is stored, no monitor is pushed it, and no notification.received is sent
    And the connection stays open
    And each retry of it is refused the same way, so @bob's atServer holds back its later notifications to @alice until it expires
