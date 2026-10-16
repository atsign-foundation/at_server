Feature: A peer that has proved itself by pol may look up only the called atSign's keys

  A connection that has proved itself as another atSign by pol may look up
  keys owned by the atSign whose atServer it called, and no other atSign's.
  A lookup naming another owner is refused with AT0009 and the connection
  closed.

  Races: the refusal reads only the request and the connection's own state.
  Replay: nothing is consumed or written before the refusal.
  DoS: the refusal compares two atSigns and closes the connection.
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
