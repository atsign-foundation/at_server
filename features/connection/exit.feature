Feature: An atServer closes a connection on @exit

  A client may end a connection by sending @exit. The atServer writes
  nothing in reply and closes the connection, whether or not the
  connection has authenticated. Commands sent before @exit on the same
  connection are answered first; anything sent after it is not handled.

  Races: @exit is taken in arrival order with the connection's other
  commands, so a command sent before it is answered before the close.
  Replay: @exit writes nothing and spends nothing.
  DoS: @exit closes only the connection that sent it. Waiting for its
  earlier replies to be sent takes at most five seconds.
  Forgery and impersonation: @exit acts only on the connection it arrives
  on, and decides nothing about who is asking.

  Scenario Outline: An atServer closes the connection on @exit
    Given <connection>
    When it sends @exit
    Then the atServer writes nothing
    And the connection is closed

    Examples:
      | connection                                            |
      | a client that has not authenticated                   |
      | a client authenticated as @alice                      |
      | a peer atServer that has proved itself as @bob by pol |

  Scenario: Commands before @exit are answered, and commands after it are not
    Given a client authenticated as @alice
    When it sends noop:0, @exit and noop:0 in one write
    Then the atServer answers the first noop:0
    And the connection is closed
    And the second noop:0 is not handled

  Scenario: A large response sent before @exit arrives whole
    Given a client authenticated as @alice
    And @alice's atServer holds a self key with a 512 KiB value
    When it sends llookup of that key and @exit in one write
    Then it receives the whole value
    And the connection is closed

  Scenario: A command that only resembles @exit is refused as before
    Given a client authenticated as @alice
    When it sends exit
    Then it is answered with AT0003
    And the connection stays open
