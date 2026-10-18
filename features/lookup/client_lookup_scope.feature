Feature: A client names another atSign's key bare when it looks it up

  An authenticated client looks up a key another atSign owns as
  <key>@<atSign>, with no scope, and its atServer looks it up from that
  atSign's atServer over pol. A lookup naming another atSign's key with a
  scope is refused with AT0009, and the atServer does not contact the other
  atSign's atServer. The client keeps its connection. A lookup of the
  client's own atSign's keys may still name a scope.

  Races: the refusal reads only the request.
  Replay: nothing is sent, consumed or written before the refusal.
  DoS: the refusal looks for a scope in the key and sends nothing to another
  atServer.
  Forgery and impersonation: the refusal changes what the atServer asks
  another atServer for, never whose data it returns.

  Scenario Outline: A client's lookup of another atSign's key with a scope is refused without asking that atSign's atServer
    Given a client authenticated as @alice
    When it sends <lookup>
    Then it is refused with AT0009: Lookup from @alice may name the key only as phone.wavi@bob, not <named>
    And @alice's atServer sends nothing to @bob's atServer
    And the connection stays open

    Examples:
      | lookup                           | named                 |
      | lookup:public:phone.wavi@bob     | public:phone.wavi@bob |
      | lookup:@carol:phone.wavi@bob     | @carol:phone.wavi@bob |
      | lookup:all:public:phone.wavi@bob | public:phone.wavi@bob |

  Scenario: A client still looks up another atSign's key named bare
    Given @bob's atServer holds @alice:phone.wavi@bob
    And a client authenticated as @alice
    When it sends lookup:phone.wavi@bob
    Then @alice's atServer sends lookup:all:phone.wavi@bob to @bob's atServer
    And the client gets that record's value

  Scenario: A client's lookup of its own atSign's key may name a scope
    Given @alice's atServer holds public:phone.wavi@alice
    And a client authenticated as @alice
    When it sends lookup:public:phone.wavi@alice
    Then it gets that record's value
