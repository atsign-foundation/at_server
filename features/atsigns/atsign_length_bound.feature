Feature: An atSign has at most 55 characters

  An atSign has at most 55 characters after its @. Characters are Unicode
  code points, counted once the atSign is lower-cased and its dots are
  removed: @a.b has 2 characters, and an emoji has 1. An atServer refuses a
  longer atSign wherever a command names one: the atSign a connection
  declares, a key's owner or recipient, a notification's recipient or
  sender, a stream's receiver, or a blocklist entry. It answers AT0003 with
  "invalid @sign: must have at most 55 characters after the @" before it
  looks anything up, stores, queues or sends anything. An authenticated
  client, or a peer that has proved itself by pol, keeps its connection.
  Any other connection is closed. An atSign of exactly 55 characters is
  accepted everywhere. An atServer does not start for an atSign longer than
  55 characters.

  Here @max stands for an atSign of 55 characters after its @, and @over
  for one of 56.

  Races: the check reads only the request, before the command reads or
  writes anything.
  Replay: nothing is written, spent or queued before the refusal, so no
  refused notification is retried after a restart.
  DoS: the check measures one string before any atDirectory lookup,
  outbound connection, access-log entry or cache read, and the answer does
  not repeat the atSign.
  Forgery: a notification is stored only as from the atSign its sender
  proved by pol, and no connection can prove an atSign longer than 55
  characters. A pol challenge naming one is not signed.
  Impersonation: from: and to: are refused before any challenge is issued,
  so no connection acts as an atSign longer than 55 characters.

  Scenario Outline: A connection that has not authenticated is refused an atSign longer than 55 characters
    Given a connection that has not authenticated
    When it sends <command>
    Then it is refused with AT0003: invalid @sign: must have at most 55 characters after the @
    And the connection is closed

    Examples:
      | command                |
      | from:@over             |
      | to:@over               |
      | lookup:phone.wavi@over |

  Scenario Outline: An atServer whose atSign has 55 characters answers for it
    Given an atServer whose atSign is @max
    When a connection that has not authenticated sends <command>
    Then <answer>

    Examples:
      | command   | answer                                         |
      | from:@max | it gets a data: challenge for @max             |
      | to:@max   | it gets @max's publickey and signing_publickey |

  Scenario: An atServer does not start for an atSign longer than 55 characters
    Given an atServer configured with @over as its atSign
    When it starts
    Then it logs invalid @sign: must have at most 55 characters after the @
    And it stops

  Scenario Outline: A client's command naming an atSign longer than 55 characters is refused before anything is done
    Given @alice's authenticated client
    When it sends <command>
    Then it is refused with AT0003: invalid @sign: must have at most 55 characters after the @
    And nothing is stored, queued, looked up or sent
    And the connection stays open

    Examples:
      | command                                                                                                                                     |
      | notify:update:messageType:key:@over:phone.wavi@alice:v                                                                                      |
      | notify:all:@bob,@over:phone.wavi@alice:v                                                                                                    |
      | update:@over:phone.wavi@alice v                                                                                                             |
      | update:@over:shared_key.bob@alice v                                                                                                         |
      | update:phone.wavi@over v                                                                                                                    |
      | update:meta:@over:phone.wavi@alice:ttl:60000                                                                                                |
      | update:json:{"atKey":"phone.wavi","sharedBy":"@alice","sharedWith":"@over","value":"v","metadata":{"isPublic":false,"isBinary":false,"isEncrypted":false}} |
      | delete:@over:phone.wavi@alice                                                                                                               |
      | delete:phone.wavi@over                                                                                                                      |
      | lookup:phone.wavi@over                                                                                                                      |
      | lookup:all:phone.wavi@over                                                                                                                  |
      | plookup:phone.wavi@over                                                                                                                     |
      | plookup:bypassCache:true:phone.wavi@over                                                                                                    |
      | llookup:phone.wavi@over                                                                                                                     |
      | llookup:@over:phone.wavi@alice                                                                                                              |
      | llookup:cached:@alice:phone.wavi@over                                                                                                       |
      | scan:@over                                                                                                                                  |
      | config:block:add:@over                                                                                                                      |
      | config:block:remove:@over                                                                                                                   |
      | stream:init@over namespace:wavi startByte:0 s1 f.txt 10                                                                                     |

  Scenario Outline: A client's command naming an atSign of exactly 55 characters is accepted
    Given @alice's authenticated client
    And @alice's atServer holds @max:phone.wavi@alice
    When it sends <command>
    Then <outcome>

    Examples:
      | command                                                 | outcome                                                       |
      | notify:update:messageType:key:@max:phone.wavi@alice:v   | a notification for @max is queued                             |
      | notify:all:@bob,@max:phone.wavi@alice:v                 | a notification for each of @bob and @max is queued            |
      | update:@max:phone.wavi@alice v                          | @max:phone.wavi@alice holds v                                 |
      | update:meta:@max:phone.wavi@alice:ttl:60000             | @max:phone.wavi@alice has a ttl of 60000                      |
      | delete:@max:phone.wavi@alice                            | @alice's atServer no longer holds @max:phone.wavi@alice       |
      | llookup:@max:phone.wavi@alice                           | it gets that record's value                                   |
      | lookup:phone.wavi@max                                   | @alice's atServer asks the atDirectory for @max               |
      | plookup:phone.wavi@max                                  | @alice's atServer asks the atDirectory for @max               |
      | scan:@max                                               | @alice's atServer asks the atDirectory for @max               |
      | config:block:add:@max                                   | config:block:show lists @max                                  |
      | stream:init@max namespace:wavi startByte:0 s1 f.txt 10  | a notification for @max is queued                             |

  Scenario Outline: An atSign is measured in characters after its @, without its dots
    Given @alice's authenticated client
    When it sends notify:update:messageType:key:<recipient>:phone.wavi@alice:v
    Then <outcome>

    Examples:
      | recipient                                 | outcome                                                    |
      | @ and 55 letters with a dot between each  | a notification for the atSign without its dots is queued   |
      | @ and 56 letters with a dot between each  | it is refused with AT0003                                  |
      | @ and 55 emoji                            | a notification for that atSign is queued                   |
      | @ and 56 emoji                            | it is refused with AT0003                                  |
      | @ and 56 capital letters                  | it is refused with AT0003                                  |

  Scenario Outline: A peer that has proved itself by pol is refused an atSign longer than 55 characters
    Given a peer that has proved itself as @bob by pol
    When it sends <command>
    Then it is refused with AT0003: invalid @sign: must have at most 55 characters after the @
    And nothing is stored
    And the connection stays open

    Examples:
      | command                                                |
      | notify:update:messageType:key:@over:phone.wavi@bob:v   |
      | notify:update:messageType:key:@alice:phone.wavi@over:v |
      | lookup:phone.wavi@over                                 |

  Scenario: A pol challenge naming a verifier longer than 55 characters is not signed
    Given @alice's client has sent lookup:phone.wavi@bob
    And @bob's atServer answers @alice's atServer's from: with a pol challenge naming @over as its verifier
    When @alice's atServer reads the challenge
    Then it does not sign the challenge
    And it does not send pol

  Scenario: An atSign with a reserved character is refused with AT0003
    Given a connection that has not authenticated
    When it sends from:@a!b
    Then it is refused with AT0003: invalid @sign: Cannot contain !*'`();:&=+$,/?#[]{} characters
    And the connection is closed
