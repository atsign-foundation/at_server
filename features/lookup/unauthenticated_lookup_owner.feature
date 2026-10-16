Feature: A connection that has not authenticated may look up only this atSign's keys

  A connection that has not authenticated, whatever it has sent first, may
  look up keys owned by this atServer's atSign and no other atSign's. A
  lookup naming another owner is refused with AT0009 and the connection
  closed. A lookup of this atSign's own keys is unchanged.

  Races: the refusal reads only the request and the connection's own state.
  Replay: nothing is consumed or written before the refusal.
  DoS: the refusal compares two atSigns and closes the connection.
  Forgery and impersonation: an unauthenticated connection reads only this
  atSign's public data, never data held here under another owner's name.

  Scenario Outline: A connection that has not authenticated may look up only the keys of the atSign it is on
    Given <connection>
    When it sends <lookup>
    Then it is refused with AT0009: Lookup on a connection that has not authenticated may read only @alice's keys, not <owner>'s
    And the connection is closed

    Examples:
      | connection                    | lookup                       | owner |
      | a client has sent from:@alice | lookup:public:phone.wavi@bob | @bob  |
      | a client has sent from:@alice | lookup:phone.wavi@bob        | @bob  |
      | a peer has sent to:@alice     | lookup:public:phone.wavi@bob | @bob  |
      | a client has sent nothing yet | lookup:public:phone.wavi@bob | @bob  |

  Scenario: A connection that has not authenticated still looks up this atSign's public keys
    Given a client has sent from:@alice
    And @alice's atServer holds public:phone.wavi@alice
    When it sends lookup:phone.wavi@alice
    Then it gets that record's value
