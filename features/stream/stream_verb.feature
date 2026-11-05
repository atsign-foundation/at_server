Feature: An atServer does not support the stream verb

  An atServer has no stream verb: every stream: command, whatever its
  operation and whichever connection sends it, is refused with AT0003 as an
  unknown verb, and nothing is queued, stored, set up or relayed for it. As
  for any command refused with AT0003, a connection that has authenticated,
  as this atSign's client or as a peer by pol, keeps its connection, and one
  that has not is closed. A batch carrying a stream: command is refused whole
  (features/batch/batch_verbs.feature).

  Races: a refused command reads and writes nothing.
  Replay: nothing is stored or consumed, so a resent command is refused again.
  DoS: a refused command costs one log line, and closes a connection that has
  not authenticated.
  Forgery and impersonation: no connection can make this atServer send a
  notification, or relay bytes, through a stream: command.

  Scenario Outline: A stream command is refused
    Given <connection>
    When it sends <command> to @alice's atServer
    Then it is refused with AT0003
    And no notification is queued or stored

    Examples:
      | connection                                   | command                                      |
      | @alice's client authenticated by pkam        | stream:init@carol namespace:wavi s1 f.txt 12 |
      | a peer that has proved itself as @bob by pol | stream:init@carol namespace:wavi s1 f.txt 12 |
      | a connection that has not authenticated      | stream:resume@carol startByte:5 s1           |
      | a connection that has not authenticated      | stream:receive s1                            |
      | a connection that has not authenticated      | stream:done s1                               |
