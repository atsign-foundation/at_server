Feature: Exchanges with no namespace
  An exchange that belongs to no namespace follows the pair's standing. It is
  permitted if the other atSign is admitted somewhere on @alice's atServer, in
  some namespace's admitted set or in the atSign-wide admitted set, and only
  for a short list: a lookup of shared_key in any form, update and delete
  notifications of the legacy copy "@<them>:shared_key@<me>", and text
  notifications until they are retired. Every other exchange with no namespace
  is refused. Being quarantined somewhere does not count as admitted. Under the
  ungated default, namespace-less traffic passes as it does today
  (rules.feature). The gate verb's grammar is in rules.feature.

  Race: the standing read here is the one rules.feature changes, from the next
  exchange.
  Replay: shared_key's value is what a lookup already returns to that atSign,
  so nothing here hands over what could not otherwise be had.
  DoS: an atSign admitted nowhere gets no namespace-less exchange at all.

  Background:
    Given @alice's atSign has the closed default

  Scenario Outline: An atSign admitted somewhere may look up the shared key
    Given @dave is admitted in "chat" on @alice's atServer
    And @alice's atServer holds "@dave:shared_key@alice"
    When @dave's atServer sends "<command>"
    Then @alice's atServer answers with the value of "@dave:shared_key@alice"

    Examples:
      | command                     |
      | lookup:shared_key@alice     |
      | lookup:all:shared_key@alice |

  Scenario: An atSign admitted only atSign-wide may look up the shared key
    Given @dave is in @alice's atSign-wide admitted set, and admitted in no namespace
    And @alice's atServer holds "@dave:shared_key@alice"
    When @dave's atServer sends "lookup:shared_key@alice"
    Then @alice's atServer answers with the value of "@dave:shared_key@alice"

  Scenario: A quarantined atSign may not look up the shared key
    Given @chuck is quarantined in "invitations.chat" on @alice's atServer, and admitted nowhere
    And @alice's atServer holds "@chuck:shared_key@alice"
    When @chuck's atServer sends "lookup:shared_key@alice"
    Then @alice's atServer answers with the not-accepted error

  Scenario: An admitted atSign's shared-key notification is cached
    Given @dave is admitted in "chat" on @alice's atServer
    When @dave's atServer sends "notify:id:1:update:ttr:3888000:@alice:shared_key@dave:<encrypted key>"
    Then @alice's atServer answers "data:success"
    And @alice's atServer holds "cached:@alice:shared_key@dave"

  Scenario: An admitted atSign's shared-key delete removes the cached copy
    Given @dave is admitted in "chat" on @alice's atServer
    And @alice's atServer holds "cached:@alice:shared_key@dave", cached with ccd
    When @dave's atServer sends "notify:id:2:delete:ttr:3888000:ccd:true:@alice:shared_key@dave"
    Then @alice's atServer answers "data:success"
    And @alice's atServer no longer holds "cached:@alice:shared_key@dave"

  Scenario: A shared-key notification from an atSign admitted nowhere is refused
    Given @chuck is quarantined in "invitations.chat" on @alice's atServer, and admitted nowhere
    When @chuck's atServer sends "notify:id:3:update:ttr:3888000:@alice:shared_key@chuck:<encrypted key>"
    Then @alice's atServer answers with the not-accepted error
    And @alice's atServer holds no "cached:@alice:shared_key@chuck"

  Scenario: A text notification from an atSign admitted somewhere is accepted
    Given @dave is admitted in "chat" on @alice's atServer
    When @dave's atServer sends "notify:id:4:messageType:text:@alice:hello"
    Then @alice's atServer answers "data:success"

  Scenario: A text notification from a quarantined atSign is refused
    Given @chuck is quarantined in "invitations.chat" on @alice's atServer, and admitted nowhere
    When @chuck's atServer sends "notify:id:5:messageType:text:@alice:hello"
    Then @alice's atServer answers with the not-accepted error

  Scenario: Any other namespace-less key is refused in a notification, even from an admitted atSign
    Given @dave is admitted in "chat" on @alice's atServer
    When @dave's atServer sends "notify:id:6:update:ttr:60000:@alice:location@dave:<value>"
    Then @alice's atServer answers with the not-accepted error
    And @alice's atServer holds no "cached:@alice:location@dave"

  Scenario: Any other namespace-less key is refused in a lookup, even for an admitted atSign
    Given @dave is admitted in "chat" on @alice's atServer
    And @alice's atServer holds "@dave:location@alice"
    When @dave's atServer sends "lookup:location@alice"
    Then @alice's atServer answers with the not-accepted error

  Scenario: @alice's lookup of a shared key goes out only to an atSign admitted somewhere
    Given @dave is admitted nowhere on @alice's atServer
    When @alice's client sends "lookup:shared_key@dave"
    Then @alice's atServer answers with the not-accepted error
    And no connection is made to @dave's atServer

  Scenario: @alice's legacy shared-key copy for an atSign admitted nowhere is stored, not notified
    Given @dave is admitted nowhere on @alice's atServer
    When @alice's client sends "update:ttr:3888000:@dave:shared_key@alice <encrypted key>"
    Then @alice's atServer answers with a commit id
    And @alice's atServer holds no notification for @dave

  Scenario: A cached shared key goes when its atSign is admitted nowhere any more
    Given @dave is admitted in "chat" only on @alice's atServer
    And @alice's atServer holds "cached:@alice:shared_key@dave"
    When @alice's chat client sends "gate:remove:chat:@dave"
    Then @alice's atServer no longer holds "cached:@alice:shared_key@dave"

  Scenario: Authentication is never gated
    Given @dave is admitted nowhere on @alice's atServer
    And @dave's atServer has sent "from:@dave" to @alice's atServer
    When @dave's atServer sends "pol"
    Then @alice's atServer looks up @dave's signed challenge on @dave's atServer
    And answers "pol:@dave@"
