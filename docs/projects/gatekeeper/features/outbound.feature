Feature: @alice's own outbound exchanges
  @alice's rules bind @alice's own atServer on the way out, for notifications
  (explicit and auto-notify), remote lookup and scan, and cache refresh. In an
  open namespace it reaches any atSign not denied there; in a closed one, only
  atSigns admitted there. Nothing @alice sends, looks up or scans changes
  another atSign's standing: an atSign @alice contacts first, and whose
  replies should arrive unquarantined, is admitted by the application. The gate
  verb's grammar is in rules.feature.

  Race: a notification queued before its recipient lost admission is checked
  again at delivery (refusals.feature). Because sending changes no standing,
  invitations that cross have nothing to race over.
  Replay: an outbound refusal is decided on @alice's own authenticated
  connection, before anything crosses the wire.
  DoS: a refused outbound exchange queues nothing and opens no connection.

  Background:
    Given @alice's atSign has the closed default

  Scenario: A notification to an atSign a closed namespace has not admitted is never sent
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @alice's client sends "notify:@chuck:msg.chat@alice"
    Then @alice's atServer answers with the not-accepted error
    And @alice's atServer holds no notification for @chuck
    And no connection is made to @chuck's atServer

  Scenario: A notification to an atSign a closed namespace has admitted is delivered
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @alice's client sends "notify:@bob:msg.chat@alice"
    Then @alice's atServer answers with a notification id
    And delivers it to @bob's atServer

  Scenario: A lookup in a closed namespace of an atSign it has not admitted is never sent
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @alice's client sends "lookup:status.chat@chuck"
    Then @alice's atServer answers with the not-accepted error
    And no connection is made to @chuck's atServer

  Scenario: In an open namespace, @alice may notify an atSign seen for the first time
    Given namespace "invitations.chat" on @alice's atServer is open
    And @dave is in none of its sets
    When @alice's client sends "notify:@dave:inv1.invitations.chat@alice"
    Then @alice's atServer delivers it to @dave's atServer
    And @dave is still in none of the sets of "invitations.chat"

  Scenario: In an open namespace, @alice may notify a quarantined atSign
    Given namespace "invitations.chat" on @alice's atServer is open
    And @chuck is quarantined in it
    When @alice's client sends "notify:@chuck:no-thanks.invitations.chat@alice"
    Then @alice's atServer delivers it to @chuck's atServer
    And @chuck is still quarantined in "invitations.chat"

  Scenario: In an open namespace, @alice may not notify a denied atSign
    Given namespace "invitations.chat" on @alice's atServer is open, with @chuck denied
    When @alice's client sends "notify:@chuck:inv2.invitations.chat@alice"
    Then @alice's atServer answers with the not-accepted error
    And no connection is made to @chuck's atServer

  Scenario: A lookup changes nobody's standing
    Given namespace "invitations.chat" on @alice's atServer is open
    And @dave is in none of its sets
    When @alice's client sends "lookup:profile.invitations.chat@dave"
    Then @alice's atServer looks it up on @dave's atServer
    And @dave is still in none of the sets of "invitations.chat"

  Scenario: A remote scan answers only keys in namespaces where @alice may reach the other atSign
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And namespace "photos" on @alice's atServer is open
    And @chuck's atServer holds "@alice:status.chat@chuck" and "@alice:pic.photos@chuck"
    When @alice's client sends "scan:@chuck"
    Then @alice's atServer answers ["pic.photos@chuck"]

  Scenario: The reply to an invitation arrives in quarantine
    Given namespace "chat" is closed and "invitations.chat" is open, on both @alice's and @dave's atServers
    And @alice's client has sent "notify:@dave:inv1.invitations.chat@alice"
    When @dave's atServer sends "notify:id:7:@alice:inv1.invitations.chat@dave"
    Then @alice's atServer answers "data:success"
    And @dave is quarantined in "invitations.chat" on @alice's atServer

  Scenario: Accepting an invitation is the application admitting the atSign
    Given namespace "chat" on @alice's atServer is closed, admitting nobody
    And @dave is quarantined in "invitations.chat" on @alice's atServer
    And @alice's chat client has sent "gate:admit:chat:@dave"
    When @alice's client sends "notify:@dave:msg.chat@alice"
    Then @alice's atServer delivers it to @dave's atServer

  Scenario: An update of a key shared with an admitted atSign is notified as today
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @alice's client sends "update:@bob:status.chat@alice <value>"
    Then @alice's atServer answers with a commit id
    And delivers a notification of "@bob:status.chat@alice" to @bob's atServer

  Scenario: A key shared with an atSign the namespace refuses is stored, and not notified
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @alice's client sends "update:@chuck:status.chat@alice <value>"
    Then @alice's atServer answers with a commit id
    And @alice's atServer holds "@chuck:status.chat@alice"
    And @alice's atServer holds no notification for @chuck

  Scenario: A stored key becomes reachable when its atSign is admitted
    Given @alice's atServer holds "@chuck:status.chat@alice"
    And @alice's chat client has sent "gate:admit:chat:@chuck"
    When @chuck's atServer sends "lookup:status.chat@alice"
    Then @alice's atServer answers with the value of "@chuck:status.chat@alice"

  Scenario: Under the ungated default, @alice reaches anyone in a namespace without a rule
    Given @alice's atSign has the ungated default
    And namespace "photos" on @alice's atServer has no rule
    When @alice's client sends "notify:@chuck:pic.photos@alice"
    Then @alice's atServer delivers it to @chuck's atServer
