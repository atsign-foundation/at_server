Feature: A connection that has authenticated with pkam may not cram, and a batch may not authenticate

  Once a pkam has succeeded on a connection, a cram on that connection is
  refused and the connection closed. A pkam after a cram, and a cram after
  a cram, are unaffected. Neither cram nor pkam is ever run inside a batch:
  there each is refused in the batch's response, whatever the connection
  authenticated with.

  Races: the refusal reads only the connection's own authentication state,
  which nothing but that connection's own commands writes.
  Replay: each cram answers a single-use challenge, so a captured digest
  answers nothing.
  DoS: the refusal reads one field and closes the connection.

  Scenario: A cram after a successful pkam on the same connection is refused and closes it
    Given a connection to @alice's atServer that has authenticated with pkam
    When it sends from:@alice and then cram:<digest>
    Then the atServer answers error:AT0009:cram may not follow a successful pkam on this connection, then the prompt @alice@
    And the connection is closed

  Scenario Outline: An authentication inside a batch is refused
    Given a connection to @alice's atServer that has authenticated with <auth>
    When it sends from:@alice and then a batch whose one command is <verb>:<proof>
    Then that command's entry in the batch response carries AT0009
    And the connection stays open, authenticated with <auth>

    Examples:
      | auth | verb |
      | pkam | cram |
      | cram | cram |
      | pkam | pkam |
      | cram | pkam |

  Scenario: A pkam after a cram on the same connection still succeeds
    Given a connection to @alice's atServer that has authenticated with cram
    When it sends from:@alice and then a valid pkam
    Then the pkam succeeds
