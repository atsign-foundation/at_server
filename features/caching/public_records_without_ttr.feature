Feature: A reader's atServer keeps no copy of a public record that has no ttr

  A public record whose owner gave it no ttr, or a ttr of 0, is not copied by
  the atServer of the atSign that looks it up. The reader gets the owner's
  current record, and nothing about it is stored, committed or synced to the
  reader's clients. A record with a ttr is copied and served within it, and
  another atSign's encryption public key is still kept indefinitely.

  Copies written before this, the leftovers, are cached:public: copies with no
  ttr. A lookup of the record removes its leftover, and the nightly cache
  refresh removes every leftover without fetching the record. A copy of a
  record another atSign shared (cached:@<reader>:...) is never treated as a
  leftover.

  A notification writes a cached copy only when it carries a ttr, so it is
  outside this feature.

  Races: a plookup and the nightly refresh can reach the same leftover at
  once. Both delete it, so whichever is second finds nothing, and neither
  writes a copy.
  Replay: a plookup carries no challenge, nonce or signature, and repeating
  one writes nothing.
  DoS: a plookup of a record with no ttr stores nothing and commits nothing,
  so repeating one cannot grow the reader's keystore, commit log or clients'
  sync. Removing a leftover happens once per copy.

  Scenario Outline: Looking up a public record with no ttr leaves nothing behind
    Given @bob's atServer holds public:<record> with <ttr>
    And @alice's atServer holds no copy of it
    When one of @alice's clients sends plookup:<options>all:<record>
    Then the client gets @bob's record
    And @alice's atServer still holds no cached:public:<record>
    And @alice's atServer commits nothing for cached:public:<record>

    Examples:
      | record                          | ttr    | options           |
      | phone.wavi@bob                  | no ttr |                   |
      | phone.wavi@bob                  | ttr 0  |                   |
      | __nskey.app@bob                 | no ttr |                   |
      | __nskey.app@bob                 | no ttr | bypassCache:true: |
      | _apsk.<enrollmentId>.a.__e@bob  | no ttr |                   |
      | _apsk.<enrollmentId>.r.__e@bob  | no ttr |                   |
      | _apsk.<enrollmentId>.d.__e@bob  | no ttr |                   |

  Scenario: A record with a ttr is still copied, and served within it
    Given @bob's atServer holds public:phone.wavi@bob with ttr 3600
    When one of @alice's clients sends plookup:all:phone.wavi@bob
    Then @alice's atServer holds cached:public:phone.wavi@bob with ttr 3600
    And another plookup within the hour is answered from that copy, without asking @bob's atServer

  Scenario: Another atSign's encryption public key is still kept indefinitely
    Given @bob's atServer holds public:publickey@bob with no ttr
    When @alice's atServer looks it up
    Then @alice's atServer holds cached:public:publickey@bob with ttr -1

  Scenario Outline: A leftover copy goes the next time the record is looked up
    Given @alice's atServer holds a leftover cached:public:<record> with no ttr
    When one of @alice's clients sends plookup:all:<record>
    Then the client gets @bob's current record
    And @alice's atServer no longer holds cached:public:<record>
    And the removal is committed, so @alice's clients drop their synced copy

    Examples:
      | record                          |
      | phone.wavi@bob                  |
      | __nskey.app@bob                 |
      | _apsk.<enrollmentId>.a.__e@bob  |

  Scenario: The nightly refresh removes a leftover nobody looks up
    Given @alice's atServer holds a leftover cached:public:phone.wavi@bob with no ttr
    When @alice's atServer runs its nightly cache refresh
    Then @alice's atServer no longer holds cached:public:phone.wavi@bob
    And the removal is committed
    And @bob's atServer is not asked for public:phone.wavi@bob

  Scenario: The nightly refresh leaves a shared copy alone
    Given @alice's atServer holds cached:@alice:phone@bob, a copy of a record @bob shared, with no ttr
    When @alice's atServer runs its nightly cache refresh
    Then that copy is refreshed as before, not deleted
