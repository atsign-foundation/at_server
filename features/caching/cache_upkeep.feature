Feature: Cache upkeep on a reader's atServer commits only real changes

  A reader's atServer refreshes its cached copies once a day and deletes a
  copy when the owner no longer has the record. Each change it makes is
  committed and synced to the reader's clients, so a change that did not
  happen is not committed. A refresh that finds the owner's value unchanged
  keeps the copy servable for another ttr. The refresh runs at the hour an
  operator sets, or at a random hour, which spreads the load across
  atServers.

  Races: a plookup miss and the nightly refresh can reach the same copy at
  once. Each deletes it only if it is there, so the second finds nothing
  to do, and both follow a not-found from the owner.
  Replay: no challenge, nonce or signature is involved.
  DoS: a plookup of a record that does not exist commits nothing, so
  repeating one cannot grow the reader's commit log or its clients' sync.

  Scenario: Looking up a record that does not exist commits nothing when no copy is held
    Given @bob's atServer has no public:email.wavi@bob
    And @alice's atServer holds no copy of it
    When one of @alice's clients sends plookup:all:email.wavi@bob
    Then the client is told it does not exist
    And @alice's atServer commits nothing for cached:public:email.wavi@bob

  Scenario: Looking up a record that no longer exists deletes the copy held
    Given @alice's atServer holds cached:public:email.wavi@bob, copied with ttr 3600 and now past its refreshAt
    And @bob's atServer no longer has public:email.wavi@bob
    When one of @alice's clients sends plookup:all:email.wavi@bob
    Then the client is told it does not exist
    And @alice's atServer no longer holds cached:public:email.wavi@bob
    And the DELETE is committed, so @alice's clients drop it too

  Scenario: A refresh that finds the value unchanged keeps the copy servable
    Given @alice's atServer holds cached:public:phone.wavi@bob, copied with ttr 3600 and now past its refreshAt
    And @bob's atServer still holds the same value for public:phone.wavi@bob, with ttr 3600
    When @alice's atServer runs its nightly cache refresh
    Then the copy's refreshAt moves an hour on
    And the next plookup within that hour is answered from the copy, without asking @bob's atServer
    And the re-written copy is committed, as a lookup's re-write is

  Scenario: The refresh runs at the hour runRefreshJobHour sets
    Given @alice's atServer starts with runRefreshJobHour set to 5
    When it schedules its cache refresh
    Then the refresh runs at 05:00 each day

  Scenario: With no runRefreshJobHour the refresh runs at a random hour
    Given @alice's atServer starts with no runRefreshJobHour
    When it schedules its cache refresh
    Then the refresh runs at an hour picked at random from 00 to 23

  Scenario Outline: A runRefreshJobHour that is not an hour is ignored with a warning
    Given @alice's atServer starts with runRefreshJobHour set to <value>
    When it schedules its cache refresh
    Then it logs a warning naming <value>
    And the refresh runs at an hour picked at random from 00 to 23

    Examples:
      | value |
      | 24    |
      | -1    |
      | three |
