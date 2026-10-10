Feature: Refusals, and losing admission
  Every gate refusal is final. The sending atServer stops at once, never
  retries, and marks the notification "refused" for its client to read with
  notify:status. A refusal says which of three it is: not accepted, quarantine
  limit reached, or too large for quarantine. Not accepted covers a closed
  namespace, an atSign not admitted, an atSign denied, and a namespace-less
  exchange off the short list, so a sender cannot tell which. A refusal answers
  one command and leaves the connection open.

  An atSign loses admission in a namespace when it is removed from the admitted
  set, when it is denied, when an open namespace it could reach is closed, when
  the owner switches the default to closed, or when it is blocklisted. Keys
  shared with it and notifications already stored from it stay. Cached copies
  of its keys go, and a notification queued for it is checked again at
  delivery. The gate verb's grammar is in rules.feature.

  Race: a notification queued before its recipient lost admission is checked
  again at delivery, and a cache refresh that completes after admission was
  lost leaves no cached copy.
  Replay: a notification refused and later resent with the same id, after its
  sender has been admitted, is accepted, and a further resend is stored once
  (quarantine.feature).
  DoS: a refusal stores nothing and opens no connection. An atServer that does
  not yet discard refusals retries one every 10 seconds until it expires, and
  each retry costs @alice's atServer one rule check.

  Background:
    Given @alice's atSign has the closed default

  Scenario: A sending atServer discards a refused notification at once
    Given @chuck's atServer is delivering notification 11 to @alice
    When @alice's atServer answers it with the quarantine-limit error
    Then @chuck's atServer does not send notification 11 again
    And "notify:status:11" on @chuck's atServer answers "refused"

  Scenario: A refusal does not hold back the next notification
    Given @chuck's atServer has notifications 11 and 12 queued for @alice, in that order
    When @alice's atServer answers notification 11 with the quarantine-limit error
    Then @chuck's atServer sends notification 12 at once

  Scenario Outline: A denied atSign and a closed namespace look the same to the sender
    Given namespace "chat" on @alice's atServer is closed
    And namespace "photos" on @alice's atServer is open, with @chuck denied
    When @chuck's atServer sends a notification in "<namespace>"
    Then @alice's atServer answers with the not-accepted error

    Examples:
      | namespace |
      | chat      |
      | photos    |

  Scenario: A gate refusal leaves the connection open
    Given @chuck's atServer has a pol-authenticated connection to @alice's atServer
    And namespace "chat" on @alice's atServer is closed
    When @chuck's atServer sends "notify:id:13:@alice:msg.chat@chuck" on that connection
    Then @alice's atServer answers with the not-accepted error
    And the connection stays open

  Scenario: Keys shared with an atSign that loses admission stay
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's atServer holds "@bob:status.chat@alice"
    When @alice's chat client sends "gate:remove:chat:@bob"
    Then @alice's atServer still holds "@bob:status.chat@alice"
    And "lookup:status.chat@alice" from @bob's atServer is answered with the not-accepted error

  Scenario: Stored notifications stay
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's atServer holds notification 7 from @bob in "chat"
    When @alice's chat client sends "gate:remove:chat:@bob"
    Then "notify:fetch:7" on @alice's atServer answers with notification 7

  Scenario: Cached copies go when an atSign is removed from a closed namespace
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's atServer holds "cached:@alice:msg.chat@bob"
    When @alice's chat client sends "gate:remove:chat:@bob"
    Then @alice's atServer no longer holds "cached:@alice:msg.chat@bob"

  Scenario: Cached copies go when an atSign is denied in an open namespace
    Given namespace "photos" on @alice's atServer is open, with @bob admitted
    And @alice's atServer holds "cached:@alice:pic.photos@bob"
    When @alice's photos client sends "gate:deny:photos:@bob"
    Then @alice's atServer no longer holds "cached:@alice:pic.photos@bob"

  Scenario: Cached copies go when an open namespace is closed to an atSign admitted only atSign-wide
    Given namespace "photos" on @alice's atServer is open
    And @bob is in @alice's atSign-wide admitted set, and admitted in no namespace
    And @alice's atServer holds "cached:@alice:pic.photos@bob"
    When @alice's photos client sends "gate:rule:photos:closed"
    Then @alice's atServer no longer holds "cached:@alice:pic.photos@bob"

  Scenario: Switching the default to closed removes cached copies in namespaces without a rule
    Given @alice's atSign has the ungated default
    And namespace "photos" on @alice's atServer has no rule
    And @alice's atServer holds "cached:@alice:pic.photos@chuck"
    When @alice's root client sends "gate:default:closed"
    Then @alice's atServer no longer holds "cached:@alice:pic.photos@chuck"

  Scenario: Blocklisting an atSign removes cached copies of its keys
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's atServer holds "cached:@alice:msg.chat@bob"
    When @alice's root client sends "config:block:add:@bob"
    Then @alice's atServer no longer holds "cached:@alice:msg.chat@bob"

  Scenario: A queued notification is checked again at delivery
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's atServer has queued notification 21 for @bob in "chat", not yet delivered
    When @alice's chat client sends "gate:remove:chat:@bob"
    Then @alice's atServer never delivers notification 21
    And "notify:status:21" on @alice's atServer answers "refused"

  Scenario: A refused cache refresh removes the cached copy
    Given @bob's atServer holds "cached:@bob:status.chat@alice"
    And @bob is not admitted in "chat" on @alice's atServer
    When @bob's atServer refreshes "cached:@bob:status.chat@alice"
    Then @alice's atServer answers with the not-accepted error
    And @bob's atServer no longer holds "cached:@bob:status.chat@alice"

  @race
  Scenario: A cache refresh that completes after admission was lost leaves no cached copy
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's atServer has begun refreshing "cached:@alice:msg.chat@bob"
    When @alice's chat client sends "gate:remove:chat:@bob" before the refresh completes
    Then @alice's atServer holds no "cached:@alice:msg.chat@bob" once the refresh completes

  @replay
  Scenario: A refused notification resent after its sender is admitted is accepted
    Given namespace "chat" on @alice's atServer is closed, admitting nobody
    And @alice's atServer has answered notification 30 from @chuck with the not-accepted error
    And @alice's chat client has since sent "gate:admit:chat:@chuck"
    When @chuck's atServer sends notification 30 again
    Then @alice's atServer answers "data:success"
    And @alice's atServer holds notification 30

  @dos
  Scenario: Each retry of a refused notification is refused, and stores nothing
    Given namespace "chat" on @alice's atServer is closed, admitting nobody
    And @chuck's atServer retries refused notifications until they expire
    When @chuck's atServer sends notification 31 for the third time
    Then @alice's atServer answers with the not-accepted error
    And @alice's atServer holds no notification 31
