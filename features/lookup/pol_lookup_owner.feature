Feature: A peer that has proved itself by pol may look up only the called atSign's keys

  A connection that has proved itself as another atSign by pol may look up
  keys owned by the atSign whose atServer it called, and no other atSign's.
  It names each key bare, as <key>@<atSign>, with no scope. A lookup naming
  another owner, or naming a key with a scope, is refused with AT0009 and the
  connection closed.

  Races: the refusal reads only the request and the connection's own state.
  Replay: nothing is consumed or written before the refusal.
  DoS: the refusal compares two atSigns, or looks for a scope in the key, and
  closes the connection.
  Forgery and impersonation: a pol-proved peer reads only what the called
  atSign shared with it, never data held here under another owner's name.

  Scenario Outline: A peer that has proved itself by pol may look up only the keys of the atSign it called
    Given a peer that has proved itself as @chuck by pol
    When it sends <lookup>
    Then it is refused with AT0009: Lookup from @chuck may read only @alice's keys, not <owner>'s
    And the connection is closed

    Examples:
      | lookup                       | owner |
      | lookup:public:phone.wavi@bob | @bob  |
      | lookup:phone.wavi@bob        | @bob  |

  Scenario: A peer that has proved itself by pol still looks up what the called atSign shared with it
    Given @alice's atServer holds @chuck:phone.wavi@alice
    And a peer that has proved itself as @chuck by pol
    When it sends lookup:phone.wavi@alice
    Then it gets that record's value

  Scenario Outline: A peer that has proved itself by pol names the key it looks up bare
    Given @alice's atServer holds public:phone.wavi@alice, @carol:phone.wavi@alice and @chuck:phone.wavi@alice
    And a peer that has proved itself as @chuck by pol
    When it sends <lookup>
    Then it is refused with AT0009: Lookup from @chuck may name the key only as phone.wavi@alice, not <named>
    And the connection is closed

    Examples:
      | lookup                             | named                   |
      | lookup:public:phone.wavi@alice     | public:phone.wavi@alice |
      | lookup:@carol:phone.wavi@alice     | @carol:phone.wavi@alice |
      | lookup:@chuck:phone.wavi@alice     | @chuck:phone.wavi@alice |
      | lookup:all:public:phone.wavi@alice | public:phone.wavi@alice |

  Scenario: A peer that has proved itself by pol still looks up a key it names bare, with its metadata
    Given @alice's atServer holds @chuck:phone.wavi@alice
    And a peer that has proved itself as @chuck by pol
    When it sends lookup:all:phone.wavi@alice
    Then it gets that record's value and metadata
