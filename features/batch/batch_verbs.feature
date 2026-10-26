Feature: A batch carries only lookup, llookup, plookup, notify, update and delete

  A batch may carry lookup, llookup, plookup, notify (the plain verb, not
  notify:list, notify:status, notify:fetch, notify:remove or notify:all),
  update (update:meta included) and delete. The atServer checks every entry
  before it runs any. When an entry is anything else (a command of another
  verb, a command no verb handles, or an entry that is not a command), the
  atServer refuses the whole batch with AT0003, naming the first such entry
  by its position, runs none of it, and keeps the connection open, still
  authenticated as it was. A batch it accepts runs its commands in order,
  each authorized as it would be on its own; one that fails is answered with
  its own error, and the others still run.

  Races: the check reads only the batch's own entries, before any of them
  runs.
  Replay: a refused batch stores and consumes nothing, so a resent one is
  refused again.
  DoS: a refused batch runs nothing and costs one warning line, however many
  entries it has.
  Forgery and impersonation: a batch can no longer authenticate, start a
  monitor, or carry another batch; each command it runs acts only as the
  connection's own authentication allows.

  Scenario Outline: A batch carrying anything but the six is refused whole
    Given a connection to @alice's atServer that has authenticated with <auth>
    And public:<key>@alice does not exist
    When it sends a batch of update:public:<key>@alice 1 and <entry>
    Then the atServer answers error:AT0003-Invalid syntax : a batch may carry only lookup, llookup, plookup, notify, update and delete; entry 2 is not one
    And public:<key>@alice still does not exist
    And the connection stays open, authenticated with <auth>

    Examples:
      | auth | entry                                          |
      | pkam | monitor                                        |
      | pkam | cram:<digest>                                  |
      | cram | pkam:<digest>                                  |
      | pkam | from:@alice                                    |
      | pkam | notify:list                                    |
      | pkam | notify:all:@bob:phone.wavi@alice:v             |
      | pkam | batch:[{"id":1,"command":"noop:0"}]            |
      | pkam | stream:init@carol namespace:wavi s1 f.txt 12   |
      | pkam | {"id":2}, an entry with no command             |

  Scenario Outline: A batch carrying one of the six runs it
    Given a connection to @alice's atServer that has authenticated with pkam
    And public:<key>@alice holds 1
    When it sends a batch whose one command is <command>
    Then that command's entry in the batch response carries its own answer, not AT0003

    Examples:
      | command                                   |
      | lookup:<key>@alice                        |
      | llookup:public:<key>@alice                |
      | plookup:<key>@alice                       |
      | notify:update:@alice:<key>.wavi@alice:v   |
      | update:public:<key>@alice 2               |
      | update:meta:public:<key>@alice:ttr:-1     |
      | delete:public:<key>@alice                 |

  Scenario: A batch runs its commands in order
    Given a connection to @alice's atServer that has authenticated with pkam
    And public:<key>@alice does not exist
    When it sends a batch of update:public:<key>@alice 1, llookup:public:<key>@alice, delete:public:<key>@alice and llookup:public:<key>@alice
    Then the second entry answers 1, and the fourth carries AT0015
