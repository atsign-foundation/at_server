Feature: Namespace rules, and who sets them
  An atSign's owner decides, at the atServer, which other atSigns may exchange
  data with it in each namespace, in both directions. A namespace is open, so
  that any atSign not denied there may reach it and one not yet admitted is
  quarantined, or closed, so that only its admitted set may. The atSign's
  default decides every namespace without a rule.

  The gate verb's grammar (decisions D19, D24 and D26; design.md, section 5.1):
    gate:default                             the atSign's default
    gate:default:ungated | gate:default:closed
                                             switch the default
    gate:rule:<ns>:open[:<setting>:<value>]  make <ns> open; settings: limit,
                                             window, size, maxQuarantined,
                                             maxQuarantinedBytes; a value of
                                             "default" follows the operator's
    gate:rule:<ns>:closed[:admit:<atSign>]   make <ns> closed, admitting only
                                             the atSigns named
    gate:rule:<ns>:none                      remove <ns>'s rule, keeping its
                                             admitted set as recorded
    gate:admit:<ns>:<atSign>                 admit in <ns>; <ns> "*" means the
                                             atSign-wide admitted set
    gate:deny:<ns>:<atSign>                  deny in an open <ns>
    gate:remove:<ns>:<atSign>                take out of <ns>'s admitted or
                                             denied set
    gate:show:<ns>                           <ns>'s rule and sets; "*" the
                                             atSign-wide admitted set
    gate:check:<ns>:<atSign>                 the verdict <atSign> gets in <ns>
    gate:list                                the namespaces with a rule or
                                             recorded admissions
  A namespace is dot-separated labels of word characters and hyphens, none
  empty, and the atServer lower-cases it. Notify commands between atServers are
  abbreviated to the fields a scenario turns on. A root enrollment holds
  "*:rw" and "__manage:rw".

  Race: a rule or set change applies from the next exchange, on a connection
  already open too, two changes to one namespace's sets at once both take
  effect, and a read answers the gate as of the last change completed.
  Replay: none arises; the gate issues nothing a peer could capture and send
  again, and decides each exchange afresh on the atSign its connection
  authenticated.
  DoS: a refusal stores nothing and opens no connection (refusals.feature), and
  the operator caps how many open namespaces an atSign may have, how many
  namespaces have a rule or recorded admissions, and how many atSigns each set
  holds, which bounds every answer too.
  Forgery: the gate takes the other atSign from the one pol authenticated,
  never from one named inside a command, and gate state changes only through
  the gate verb (the scenarios tagged @forgery).
  Impersonation: the gate rests on pol's proof of the other atSign, which this
  feature leaves as it is. Another atSign cannot change @alice's gate, and an
  enrollment changes and reads only the gates its namespaces, or a root
  enrollment, allow (the scenarios tagged @impersonation).

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

  Scenario: Another atServer cannot open a stream
    Given @chuck's atServer has a pol-authenticated connection to @alice's atServer
    When @chuck's atServer sends "stream:init@alice namespace:invitations.chat 1 photo.jpg 1024"
    Then @alice's atServer answers with the invalid-syntax error, AT0003

  Scenario: A closed namespace accepts an atSign it has admitted
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @bob's atServer sends "notify:id:2:@alice:msg.chat@bob"
    Then @alice's atServer answers "data:success"

  Scenario: A value reference resolves only into a namespace where the atSign is admitted
    Given @bob is admitted in "chat" and in no other namespace on @alice's atServer
    And @alice's atServer holds "@bob:card.chat@alice" with the value "atsign://photo.photos@alice"
    And @alice's atServer holds "@bob:photo.photos@alice"
    When @bob's atServer sends "lookup:card.chat@alice"
    Then @alice's atServer answers "data:null"

  Scenario: A value reference into a namespace where the atSign is admitted resolves as today
    Given @bob is admitted in "chat" and in "photos" on @alice's atServer
    And @alice's atServer holds "@bob:card.chat@alice" with the value "atsign://photo.photos@alice"
    And @alice's atServer holds "@bob:photo.photos@alice"
    When @bob's atServer sends "lookup:card.chat@alice"
    Then @alice's atServer answers with the value of "@bob:photo.photos@alice"

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
    Then @alice's atServer answers "data:success"
    And namespace "chat" on @alice's atServer is open

  Scenario: An application denies an atSign in a namespace it holds
    Given @alice's client is enrolled with "chat:rw" only
    And namespace "chat" on @alice's atServer is open, with @chuck quarantined
    When the client sends "gate:deny:chat:@chuck"
    Then @alice's atServer answers "data:success"
    And @chuck is denied in "chat"

  Scenario: An application admits an atSign in a namespace it holds
    Given @alice's client is enrolled with "chat:rw" only
    And namespace "chat" on @alice's atServer is open, with @chuck quarantined
    When the client sends "gate:admit:chat:@chuck"
    Then @alice's atServer answers "data:success"
    And @chuck is admitted in "chat"

  Scenario: Holding a namespace covers the namespaces beneath it
    Given @alice's client is enrolled with "chat:rw" only
    When the client sends "gate:rule:invitations.chat:open"
    Then @alice's atServer answers "data:success"
    And namespace "invitations.chat" on @alice's atServer is open

  @impersonation
  Scenario Outline: An application may not change a gate it does not hold
    Given @alice's client is enrolled with "<enrolled>" only
    When the client sends "<command>"
    Then @alice's atServer answers with the unauthorized error, AT0009

    Examples:
      | enrolled            | command                 |
      | chat:rw             | gate:admit:photos:@dave |
      | invitations.chat:rw | gate:rule:chat:open     |
      | chat:r              | gate:admit:chat:@dave   |
      | chat:r              | gate:rule:chat:none     |

  Scenario: Reading a namespace's gate takes read access to it
    Given @alice's client is enrolled with "chat:r" only
    When the client sends "gate:show:chat"
    Then @alice's atServer answers with the rule and sets of "chat"

  Scenario: A closed namespace answers its settings and both its sets
    Given namespace "photos" on @alice's atServer is open, with the limit 3, @bob admitted and @chuck denied
    And @alice's photos client has since sent "gate:rule:photos:closed"
    When @alice's photos client sends "gate:show:photos"
    Then @alice's atServer answers
      """
      data:{"namespace":"photos","mode":"closed","settings":{"limit":3,"window":86400,"size":15360,"maxQuarantined":100,"maxQuarantinedBytes":1048576},"admitted":["@bob"],"denied":["@chuck"]}
      """

  Scenario: A namespace without a rule answers the default and the admissions recorded there
    Given namespace "chat" on @alice's atServer has no rule, with @bob admitted
    And @alice's client is enrolled with "chat:r" only
    When the client sends "gate:show:chat"
    Then @alice's atServer answers
      """
      data:{"namespace":"chat","mode":"none","default":"closed","admitted":["@bob"]}
      """

  Scenario: Checking an atSign takes read access to the namespace
    Given namespace "chat" on @alice's atServer is open, with @chuck denied
    And @alice's client is enrolled with "chat:r" only
    When the client sends "gate:check:chat:@chuck"
    Then @alice's atServer answers
      """
      data:{"namespace":"chat","atSign":"@chuck","verdict":"notAccepted"}
      """

  Scenario: A check answers for the atSign-wide admitted set without showing it
    Given namespace "photos" on @alice's atServer is open
    And @bob is in @alice's atSign-wide admitted set
    And @alice's client is enrolled with "photos:r" only
    When the client sends "gate:check:photos:@bob"
    Then @alice's atServer answers
      """
      data:{"namespace":"photos","atSign":"@bob","verdict":"admitted"}
      """

  Scenario: A namespace that a broader rule decides names it
    Given namespace "chat" on @alice's atServer is closed, admitting only @carol
    And namespace "invitations.chat" has no rule
    And @alice's client is enrolled with "invitations.chat:r" only
    When the client sends "gate:show:invitations.chat"
    Then @alice's atServer answers
      """
      data:{"namespace":"invitations.chat","mode":"none","default":"closed","admitted":[],"governedBy":"chat"}
      """

  Scenario Outline: A check answers an atSign's standing, and nothing else
    Given <state>
    And @alice's client holds a root enrollment
    When the client sends "gate:check:<namespace>:<atSign>"
    Then @alice's atServer answers
      """
      data:{"namespace":"<namespace>","atSign":"<atSign>","verdict":"<verdict>"}
      """

    Examples:
      | state                                                                                       | namespace        | atSign | verdict     |
      | namespace "photos" on @alice's atServer is open                                             | photos           | @dave  | quarantined |
      | @alice's atSign has the ungated default, and no rule covers "photos"                        | photos           | @dave  | admitted    |
      | namespace "chat" has no rule, with @bob admitted, and no rule covers "group.chat"           | group.chat       | @bob   | admitted    |
      | namespace "chat" on @alice's atServer is closed, admitting only @bob                        | chat             | @alice | admitted    |
      | namespace "photos" is open, and @chuck is on @alice's blocklist                             | photos           | @chuck | quarantined |
      | @chuck is quarantined in open "invitations.chat", at its limit of exchanges in the window   | invitations.chat | @chuck | quarantined |

  Scenario: Any enrollment reads the default
    Given @alice's client is enrolled with "chat:r" only
    When the client sends "gate:default"
    Then @alice's atServer answers "data:closed"

  Scenario: A namespace is lower-cased
    Given @alice's client holds a root enrollment
    When the client sends "gate:rule:Chat:closed:admit:@bob"
    Then @alice's atServer answers "data:success"
    And namespace "chat" on @alice's atServer is closed, admitting only @bob

  Scenario Outline: A namespace with an empty label does not parse
    Given @alice's client holds a root enrollment
    When the client sends "<command>"
    Then @alice's atServer answers with the invalid-syntax error, AT0003

    Examples:
      | command                  |
      | gate:rule:.chat:open     |
      | gate:admit:a..chat:@bob  |
      | gate:show:chat.          |
      | gate:check:.chat:@bob    |

  Scenario: A root connection reads the atSign-wide admitted set
    Given @dave and @bob are in @alice's atSign-wide admitted set
    And @alice's client holds a root enrollment
    When the client sends "gate:show:*"
    Then @alice's atServer answers
      """
      data:{"namespace":"*","admitted":["@bob","@dave"]}
      """

  Scenario: A root connection lists every namespace with a rule or recorded admissions
    Given namespaces "chat" and "photos" on @alice's atServer have rules
    And namespace "sshnp" has no rule, with @bob admitted
    And @alice's client holds a root enrollment
    When the client sends "gate:list"
    Then @alice's atServer answers
      """
      data:["chat","photos","sshnp"]
      """

  Scenario: Any other connection lists the namespaces its enrollment holds
    Given namespaces "chat", "invitations.chat" and "photos" on @alice's atServer have rules
    And @alice's client is enrolled with "chat:r" only
    When the client sends "gate:list"
    Then @alice's atServer answers
      """
      data:["chat","invitations.chat"]
      """

  @impersonation
  Scenario Outline: An application may not read a gate it does not hold
    Given @alice's client is enrolled with "<enrolled>" only
    When the client sends "<command>"
    Then @alice's atServer answers with the unauthorized error, AT0009

    Examples:
      | enrolled | command                |
      | chat:rw  | gate:show:photos       |
      | chat:rw  | gate:check:photos:@bob |
      | *:rw     | gate:show:*            |

  @impersonation
  Scenario: An enrollment holding "*" without "__manage" may not change the atSign-wide admitted set
    Given @alice's client is enrolled with "*:rw" only
    When the client sends "gate:admit:*:@dave"
    Then @alice's atServer answers with the unauthorized error, AT0009
    And @dave is not in @alice's atSign-wide admitted set

  Scenario: A root enrollment changes the atSign-wide admitted set
    Given @alice's client holds a root enrollment
    When the client sends "gate:admit:*:@dave"
    Then @alice's atServer answers "data:success"
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
    Given no rule covers "photos" on @alice's atServer, and no admissions are recorded on it
    When @chuck's atServer sends "notify:id:13:@alice:pic.photos@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario: An application records an admission in a namespace without a rule
    Given @alice's atSign has the ungated default
    And namespace "chat" on @alice's atServer has no rule
    And @alice's client is enrolled with "chat:rw" only
    When the client sends "gate:admit:chat:@bob"
    Then @alice's atServer answers "data:success"
    And @bob is admitted in "chat"
    And namespace "chat" on @alice's atServer has no rule

  Scenario: Under the closed default, a namespace without a rule admits the atSigns recorded there
    Given namespace "chat" on @alice's atServer has no rule, with @bob admitted
    When @bob's atServer sends "notify:id:17:@alice:msg.chat@bob"
    Then @alice's atServer answers "data:success"

  Scenario: Admissions recorded without a rule cover the namespaces beneath
    Given namespace "chat" on @alice's atServer has no rule, with @bob admitted
    And no rule covers "group.chat"
    When @bob's atServer sends "notify:id:18:@alice:msg.group.chat@bob"
    Then @alice's atServer answers "data:success"

  Scenario: Admissions recorded on the namespaces covering a key add up
    Given namespace "chat" on @alice's atServer has no rule, with @bob admitted
    And namespace "invitations.chat" has no rule, with @dave admitted
    When @bob's atServer sends "notify:id:19:@alice:inv1.invitations.chat@bob"
    Then @alice's atServer answers "data:success"

  Scenario: A rule set beneath admissions recorded above it starts from its own
    Given namespace "chat" on @alice's atServer has no rule, with @bob admitted
    And @alice's chat client has sent "gate:rule:invitations.chat:closed"
    When @bob's atServer sends "notify:id:23:@alice:inv1.invitations.chat@bob"
    Then @alice's atServer answers with the not-accepted error

  Scenario: Under the closed default, the atSign-wide admitted set reaches a namespace without a rule
    Given no rule covers "photos" on @alice's atServer, and no admissions are recorded on it
    And @bob is in @alice's atSign-wide admitted set
    When @bob's atServer sends "notify:id:24:@alice:pic.photos@bob"
    Then @alice's atServer answers "data:success"

  Scenario: A rule decides over admissions recorded beneath it
    Given namespace "chat" on @alice's atServer is closed, admitting only @carol
    And namespace "invitations.chat" has no rule, with @dave admitted
    When @dave's atServer sends "notify:id:20:@alice:inv1.invitations.chat@dave"
    Then @alice's atServer answers with the not-accepted error

  Scenario: Under the ungated default, admissions recorded beneath a rule leave it in force
    Given @alice's atSign has the ungated default
    And namespace "chat" on @alice's atServer is closed, admitting only @carol
    And namespace "invitations.chat" has no rule, with @dave admitted
    When @chuck's atServer sends "notify:id:21:@alice:inv1.invitations.chat@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario: A rule set on a namespace starts from the admissions recorded there
    Given namespace "chat" on @alice's atServer has no rule, with @bob admitted
    When @alice's chat client sends "gate:rule:chat:open"
    Then namespace "chat" on @alice's atServer is open
    And @bob is admitted in "chat"

  Scenario: An application removes the rule for a namespace it holds
    Given @alice's client is enrolled with "chat:rw" only
    And namespace "chat" on @alice's atServer is open, with @bob admitted and @chuck denied
    When the client sends "gate:rule:chat:none"
    Then @alice's atServer answers "data:success"
    And namespace "chat" on @alice's atServer has no rule, with @bob admitted
    And @chuck is denied nowhere on @alice's atServer

  Scenario: Removing the last admission recorded without a rule leaves nothing to list
    Given namespace "chat" on @alice's atServer has no rule, with @bob admitted
    And @alice's client holds a root enrollment
    When the client sends "gate:remove:chat:@bob"
    Then @alice's atServer answers "data:success"
    And "gate:list" on @alice's atServer does not answer "chat"

  Scenario: Under the closed default, namespace-less traffic follows its own short list
    Given @chuck is admitted nowhere on @alice's atServer
    When @chuck's atServer sends "notify:id:14:messageType:text:@alice:hello"
    Then @alice's atServer answers with the not-accepted error

  @impersonation
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
    Then @alice's atServer answers "data:success"
    And @alice's atSign has the closed default

  Scenario: A new atSign starts with the operator's default
    Given @erin's atServer is configured so that a new atSign starts with the closed default
    When @erin's atSign is activated
    Then "gate:default" on @erin's atServer answers "data:closed"

  Scenario: An atSign activated before its atServer had the gate keeps the ungated default
    Given @alice's atSign was activated before its atServer had the gate
    And @alice's atServer is configured so that a new atSign starts with the closed default
    When @alice's atServer first runs with the gate
    Then "gate:default" on @alice's atServer answers "data:ungated"

  Scenario: A change to the operator's default leaves each atSign's default as it was
    Given @erin's atSign has the closed default
    And @erin's atServer is now configured so that a new atSign starts with the ungated default
    When @erin's atServer restarts
    Then "gate:default" on @erin's atServer answers "data:closed"

  Scenario: Setting a rule admits only the atSigns the application names
    Given @alice's atServer holds "@bob:status.chat@alice" and "@carol:status.chat@alice"
    And namespace "chat" on @alice's atServer has no rule, and no admissions are recorded on it
    When @alice's chat client sends "gate:rule:chat:closed:admit:@bob"
    Then @bob is admitted in "chat"
    And @carol is not admitted in "chat"

  Scenario: A namespace reopened refuses the atSigns it denied before it was closed
    Given namespace "photos" on @alice's atServer is open, with @chuck denied
    And @alice's photos client has since sent "gate:rule:photos:closed" and then "gate:rule:photos:open"
    When @chuck's atServer sends "notify:id:22:@alice:pic.photos@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario Outline: Admitting a denied atSign takes it out of the denied set
    Given namespace "photos" on @alice's atServer is open, with @chuck denied
    And @alice's photos client has since sent "gate:rule:photos:<mode>"
    When @alice's photos client sends "gate:admit:photos:@chuck"
    Then @alice's atServer answers "data:success"
    And @chuck is admitted in "photos" and denied nowhere on @alice's atServer

    Examples:
      | mode   |
      | open   |
      | closed |

  Scenario: Removing an atSign from a closed namespace's kept denied set
    Given namespace "photos" on @alice's atServer is open, with @chuck denied
    And @alice's photos client has since sent "gate:rule:photos:closed"
    When @alice's photos client sends "gate:remove:photos:@chuck"
    Then @alice's atServer answers "data:success"
    And @chuck is denied nowhere on @alice's atServer

  Scenario Outline: Denying in a namespace that is not open is refused
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And namespace "photos" on @alice's atServer has no rule
    And @alice's client holds a root enrollment
    When the client sends "<command>"
    Then @alice's atServer answers with the illegal-argument error, AT0022, "Only an open namespace denies; <ns> is not open"
    And @chuck is denied nowhere on @alice's atServer

    Examples:
      | command                 | ns     |
      | gate:deny:chat:@chuck   | chat   |
      | gate:deny:photos:@chuck | photos |
      | gate:deny:*:@chuck      | *      |

  Scenario: Re-issuing a rule changes only the setting it names
    Given namespace "invitations.chat" on @alice's atServer is open, with the limit 3 and @bob admitted
    When @alice's chat client sends "gate:rule:invitations.chat:open:window:7200"
    Then the rule for "invitations.chat" has the limit 3 and the window 7200
    And @bob is admitted in "invitations.chat"

  Scenario: A setting returned to the default follows the operator's
    Given the operator's default limit on @alice's atServer is 10
    And namespace "invitations.chat" on @alice's atServer is open, with the limit 3
    When @alice's chat client sends "gate:rule:invitations.chat:open:limit:default"
    Then the rule for "invitations.chat" has the limit 10
    And once the operator's default limit is 20, the rule for "invitations.chat" has the limit 20

  @dos
  Scenario: Opening a namespace beyond the atSign's cap is refused
    Given @alice's atServer allows an atSign 50 open namespaces
    And @alice's atSign has 50 open namespaces
    And @alice's client is enrolled with "chat:rw" only
    When the client sends "gate:rule:x51.chat:open"
    Then @alice's atServer answers with the illegal-argument error, AT0022, "This atSign already has 50 open namespaces, the most it may have"
    And namespace "x51.chat" on @alice's atServer has no rule

  @dos
  Scenario Outline: A set or a count of namespaces beyond the operator's cap is refused
    Given @alice's atServer allows <cap>
    And <full>
    And @alice's client holds a root enrollment
    When the client sends "<command>"
    Then @alice's atServer answers with the illegal-argument error, AT0022, "<message>"
    And @alice's gate is unchanged

    Examples:
      | cap                                                 | full                                                | command                     | message                                                                                          |
      | 10,000 admitted atSigns in a namespace              | "chat" has 10,000 admitted                          | gate:admit:chat:@dave       | chat already admits 10000 atSigns, the most it may                                               |
      | 10,000 denied atSigns in a namespace                | "photos" is open, with 10,000 denied                | gate:deny:photos:@dave      | photos already denies 10000 atSigns, the most it may                                             |
      | 10,000 atSigns in the atSign-wide admitted set      | @alice's atSign-wide admitted set holds 10,000      | gate:admit:*:@dave          | The atSign-wide admitted set already holds 10000 atSigns, the most it may                        |
      | 1,000 namespaces with a rule or recorded admissions | 1,000 namespaces have a rule or recorded admissions | gate:admit:x1001.chat:@dave | This atSign already has 1000 namespaces with a rule or recorded admissions, the most it may have |
      | 1,000 namespaces with a rule or recorded admissions | 1,000 namespaces have a rule or recorded admissions | gate:rule:x1001.chat:closed | This atSign already has 1000 namespaces with a rule or recorded admissions, the most it may have |

  Scenario: Admitting an atSign already admitted in a full namespace succeeds
    Given @alice's atServer allows 10,000 admitted atSigns in a namespace
    And "chat" has 10,000 admitted, @bob among them
    When @alice's chat client sends "gate:admit:chat:@bob"
    Then @alice's atServer answers "data:success"

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

  @forgery
  Scenario: The gate decides on the authenticated atSign, not one named in the command
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    When @chuck's atServer sends "notify:id:16:@alice:msg.chat@bob"
    Then @alice's atServer answers with the unauthorized error, AT0009

  @forgery
  Scenario Outline: A gate record cannot be changed except through the gate verb
    Given namespace "chat" on @alice's atServer is closed, admitting only @bob
    And @alice's client holds a root enrollment
    When the client sends "<command>"
    Then @alice's atServer answers with the unauthorized error, AT0009
    And namespace "chat" on @alice's atServer is still closed, admitting only @bob

    Examples:
      | command                                            |
      | keys:delete:keyName:local:chat.rule.gate@alice     |
      | notify:update:@alice:local:chat.rule.gate@alice:{} |

  @impersonation
  Scenario: Another atSign may not change @alice's gate
    Given @chuck's atServer has a pol-authenticated connection to @alice's atServer
    When @chuck's atServer sends "gate:admit:chat:@chuck"
    Then @alice's atServer answers with the unauthenticated error, AT0401
    And @chuck is not admitted in "chat"
