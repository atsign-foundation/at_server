Feature: Namespace rules, and who sets them
  An atSign's owner decides, at the atServer, which other atSigns may exchange
  data with it in each namespace, in both directions. A namespace is open, so
  that any atSign not denied there may reach it and one not yet admitted is
  quarantined, or closed, so that only its admitted set may. The atSign's
  default decides every namespace without a rule.

  Commands spelled "gate:..." are provisional, and design settles them:
    gate:default                             the atSign's default
    gate:default:ungated | gate:default:closed
                                             switch the default
    gate:rule:<ns>:open[:<setting>:<value>]  make <ns> open; settings: limit,
                                             window, size, maxQuarantined,
                                             maxQuarantinedBytes
    gate:rule:<ns>:closed[:admit:<atSign>]   make <ns> closed, admitting only
                                             the atSigns named
    gate:admit:<ns>:<atSign>                 admit in <ns>; <ns> "*" means the
                                             atSign-wide admitted set
    gate:deny:<ns>:<atSign>                  deny in an open <ns>
    gate:remove:<ns>:<atSign>                take out of <ns>'s admitted or
                                             denied set
    gate:show:<ns>                           <ns>'s rule and sets
  Notify commands between atServers are abbreviated to the fields a scenario
  turns on. A root enrollment holds "*:rw" and "__manage:rw".

  Race: a rule or set change applies from the next exchange, on a connection
  already open too, and two changes to one namespace's sets at once both take
  effect.
  Replay: the gate decides on the atSign that pol authenticated, never on one
  named inside a command, and another atSign cannot change @alice's gate.
  DoS: a refusal stores nothing and opens no connection (refusals.feature).

  Background:
    Given @alice's atSign has the closed default

  Scenario Outline: A closed namespace refuses an atSign it has not admitted
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's atServer holds "@chuck:status.chat@alice"
    When @chuck's atServer sends "<command>"
    Then @alice's atServer answers with the not-accepted error

    Examples:
      | command                           |
      | notify:id:1:@alice:msg.chat@chuck |
      | lookup:status.chat@alice          |
      | lookup:all:status.chat@alice      |

  Scenario: A closed namespace accepts an atSign it has admitted
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @bob's atServer sends "notify:id:2:@alice:msg.chat@bob"
    Then @alice's atServer answers "data:success"

  Scenario: An open namespace refuses an atSign denied there
    Given namespace "photos" on @alice's atServer is open, with @chuck denied
    When @chuck's atServer sends "notify:id:3:@alice:pic.photos@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario: A blocklisted atSign is refused at from:, whatever the namespace
    Given namespace "photos" on @alice's atServer is open
    And @chuck is on @alice's blocklist
    When @chuck's atServer sends "from:@chuck"
    Then @alice's atServer answers with AT0013
    And closes the connection

  Scenario: A notification between @alice's own clients is never gated
    Given namespace "chat" on @alice's atServer is closed, admitting nobody
    When @alice's client sends "notify:@alice:msg.chat@alice"
    Then @alice's atServer answers with a notification id

  Scenario: Admission in one namespace does not carry to another
    Given namespaces "chat" and "photos" on @alice's atServer are open
    And @bob is admitted in "chat"
    When @bob's atServer sends "notify:id:4:@alice:pic.photos@bob"
    Then @alice's atServer answers "data:success"
    And @bob is quarantined in "photos"

  Scenario: The atSign-wide admitted set admits in every open namespace
    Given namespace "photos" on @alice's atServer is open
    And @bob is in @alice's atSign-wide admitted set
    When @bob's atServer sends "notify:id:5:@alice:pic.photos@bob"
    Then @alice's atServer answers "data:success"
    And @bob is not quarantined in "photos"

  Scenario: The atSign-wide admitted set does not open a closed namespace
    Given namespace "sshnp" on @alice's atServer is closed, admitting only @carol
    And @bob is in @alice's atSign-wide admitted set
    When @bob's atServer sends "notify:id:6:@alice:req.sshnp@bob"
    Then @alice's atServer answers with the not-accepted error

  Scenario: A namespace's deny overrides the atSign-wide admitted set
    Given namespace "photos" on @alice's atServer is open, with @bob denied
    And @bob is in @alice's atSign-wide admitted set
    When @bob's atServer sends "notify:id:7:@alice:pic.photos@bob"
    Then @alice's atServer answers with the not-accepted error

  Scenario: A rule covers the namespaces beneath it
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @chuck's atServer sends "notify:id:8:@alice:msg.group.chat@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario: The more specific rule decides
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And namespace "invitations.chat" is open
    When @chuck's atServer sends "notify:id:9:@alice:inv1.invitations.chat@chuck"
    Then @alice's atServer answers "data:success"
    And @chuck is quarantined in "invitations.chat"

  Scenario: An application sets the rule for a namespace it holds
    Given @alice's client is enrolled with "chat:rw" only
    When the client sends "gate:rule:chat:open"
    Then @alice's atServer answers success
    And namespace "chat" on @alice's atServer is open

  Scenario: An application denies an atSign in a namespace it holds
    Given @alice's client is enrolled with "chat:rw" only
    And namespace "chat" on @alice's atServer is open, with @chuck quarantined
    When the client sends "gate:deny:chat:@chuck"
    Then @alice's atServer answers success
    And @chuck is denied in "chat"

  Scenario: An application admits an atSign in a namespace it holds
    Given @alice's client is enrolled with "chat:rw" only
    And namespace "chat" on @alice's atServer is open, with @chuck quarantined
    When the client sends "gate:admit:chat:@chuck"
    Then @alice's atServer answers success
    And @chuck is admitted in "chat"

  Scenario: Holding a namespace covers the namespaces beneath it
    Given @alice's client is enrolled with "chat:rw" only
    When the client sends "gate:rule:invitations.chat:open"
    Then @alice's atServer answers success
    And namespace "invitations.chat" on @alice's atServer is open

  Scenario Outline: An application may not change a gate it does not hold
    Given @alice's client is enrolled with "<enrolled>" only
    When the client sends "<command>"
    Then @alice's atServer answers with the unauthorized error, AT0009

    Examples:
      | enrolled            | command                 |
      | chat:rw             | gate:admit:photos:@dave |
      | invitations.chat:rw | gate:rule:chat:open     |
      | chat:r              | gate:admit:chat:@dave   |

  Scenario: Reading a namespace's gate takes read access to it
    Given @alice's client is enrolled with "chat:r" only
    When the client sends "gate:show:chat"
    Then @alice's atServer answers with the rule and sets of "chat"

  Scenario: An enrollment holding "*" without "__manage" may not change the atSign-wide admitted set
    Given @alice's client is enrolled with "*:rw" only
    When the client sends "gate:admit:*:@dave"
    Then @alice's atServer answers with the unauthorized error, AT0009
    And @dave is not in @alice's atSign-wide admitted set

  Scenario: A root enrollment changes the atSign-wide admitted set
    Given @alice's client holds a root enrollment
    When the client sends "gate:admit:*:@dave"
    Then @alice's atServer answers success
    And @dave is in @alice's atSign-wide admitted set

  Scenario: Under the ungated default, a namespace without a rule passes as today
    Given @alice's atSign has the ungated default
    And namespace "photos" on @alice's atServer has no rule
    When @chuck's atServer sends "notify:id:10:update:ttr:60000:@alice:pic.photos@chuck:<value>"
    Then @alice's atServer answers "data:success"
    And @alice's atServer holds "cached:@alice:pic.photos@chuck"

  Scenario: Under the ungated default, namespace-less traffic passes as today
    Given @alice's atSign has the ungated default
    And @chuck is admitted nowhere on @alice's atServer
    When @chuck's atServer sends "notify:id:11:messageType:text:@alice:hello"
    Then @alice's atServer answers "data:success"

  Scenario: Under the ungated default, a namespace with a rule is gated
    Given @alice's atSign has the ungated default
    And namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @chuck's atServer sends "notify:id:12:@alice:msg.chat@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario: Under the closed default, a namespace without a rule is closed
    Given namespace "photos" on @alice's atServer has no rule
    When @chuck's atServer sends "notify:id:13:@alice:pic.photos@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario: Under the closed default, namespace-less traffic follows its own short list
    Given @chuck is admitted nowhere on @alice's atServer
    When @chuck's atServer sends "notify:id:14:messageType:text:@alice:hello"
    Then @alice's atServer answers with the not-accepted error

  Scenario: Only a root connection switches the default
    Given @alice's atSign has the ungated default
    And @alice's client is enrolled with "chat:rw" only
    When the client sends "gate:default:closed"
    Then @alice's atServer answers with the unauthorized error, AT0009
    And @alice's atSign still has the ungated default

  Scenario: A root connection switches the default
    Given @alice's atSign has the ungated default
    And @alice's client holds a root enrollment
    When the client sends "gate:default:closed"
    Then @alice's atServer answers success
    And @alice's atSign has the closed default

  Scenario: A new atSign starts with the operator's default
    Given @erin's atServer is configured so that a new atSign starts with the closed default
    When @erin's atSign is activated
    Then "gate:default" on @erin's atServer answers "closed"

  Scenario: Setting a rule admits only the atSigns the application names
    Given @alice's atServer holds "@bob:status.chat@alice" and "@carol:status.chat@alice"
    And namespace "chat" on @alice's atServer has no rule
    When @alice's chat client sends "gate:rule:chat:closed:admit:@bob"
    Then @bob is admitted in "chat"
    And @carol is not admitted in "chat"

  @race
  Scenario: Two admissions in one namespace at once both take effect
    Given namespace "chat" on @alice's atServer is closed, admitting nobody
    When two of @alice's clients send "gate:admit:chat:@bob" and "gate:admit:chat:@dave" at the same moment
    Then @bob and @dave are both admitted in "chat"

  @race
  Scenario: A rule change applies to a connection already open
    Given @chuck's atServer has a pol-authenticated connection to @alice's atServer
    And namespace "photos" on @alice's atServer was open when it connected
    And @alice's client has since sent "gate:rule:photos:closed"
    When @chuck's atServer sends "notify:id:15:@alice:pic.photos@chuck" on that connection
    Then @alice's atServer answers with the not-accepted error

  @replay
  Scenario: The gate decides on the authenticated atSign, not one named in the command
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @chuck's atServer sends "notify:id:16:@alice:msg.chat@bob"
    Then @alice's atServer answers with the unauthorized error, AT0009

  @replay
  Scenario: Another atSign may not change @alice's gate
    Given @chuck's atServer has a pol-authenticated connection to @alice's atServer
    When @chuck's atServer sends "gate:admit:chat:@chuck"
    Then @alice's atServer answers with the unauthenticated error, AT0401
    And @chuck is not admitted in "chat"
