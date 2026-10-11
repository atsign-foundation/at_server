Feature: An expired enrollment's data moves the first time it is looked up

  When a lookup, llookup or HTTP GET of an enrollment's own data
  (<key>.<enrollmentId>.<a|r|d>.__e@<atSign>) finds that enrollment
  expired, the atServer removes the enrollment then, as the expiry sweep
  would, so its data moves to .d.__e before the lookup is answered. The
  lookup of .a.__e data is told it does not exist, and a lookup of the same
  key at .d.__e straight after finds it. The expiry sweep stays as the
  backstop.

  The enrollment read that every verb and authorisation check share never
  removes anything. Only the three lookups of an enrollment's own data do,
  inside the atSign's enrollment-mutation critical section, through the
  same removal the sweep uses, so the same hooks fire. Every removal of an
  enrollment record, the sweep's and an owner's delete included, moves the
  enrollment's data inside that critical section.

  Moving a removed enrollment's data to .d.__e commits nothing: no client of
  that enrollment can connect again, no other enrollment reads its private
  data, and its public signing key is read from the atServer. Moves to
  .r.__e on a revoke, and back to .a.__e on an unrevoke, still commit.

  Races: a lookup and the expiry sweep, or two lookups, can reach the same
  expired enrollment at once. Its data moves once and its record is removed
  once, and neither caller fails.
  Replay: no challenge, nonce or signature is involved; a repeated lookup
  finds the enrollment already removed and moves nothing.
  DoS: an expired enrollment can be moved only once, and a lookup of data
  whose enrollment is live, or does not exist, writes nothing, so no lookup
  makes the atServer do more work than the sweep would.

  Scenario Outline: The first lookup after an enrollment expires moves its data
    Given @bob's enrollment E has expired, and the expiry sweep has not run
    When <caller> sends <request> to @bob's atServer
    Then it is told the key does not exist
    And @bob's atServer holds public:_apsk.E.d.__e@bob, with E's other data at .d.__e
    And E's record is gone, exactly as after the sweep
    And nothing is committed for E's record or for any of E's data
    And a lookup of public:_apsk.E.d.__e@bob straight after finds it

    Examples:
      | caller                | request                              |
      | @alice's atServer     | lookup:_apsk.E.a.__e@bob             |
      | one of @bob's clients | llookup:public:_apsk.E.a.__e@bob     |
      | anyone                | an HTTP GET of public:_apsk.E.a.__e@bob |

  Scenario: A lookup of a live enrollment's data moves nothing
    Given @bob's enrollment E is approved and has not expired
    When @alice's atServer sends lookup:_apsk.E.a.__e@bob to @bob's atServer
    Then it gets E's signing key
    And E's record and data are where they were

  Scenario: A lookup and the expiry sweep reach an expired enrollment at once
    Given @bob's enrollment E has expired
    When a lookup of E's data and the expiry sweep reach E at the same moment
    Then E's data ends up at .d.__e once, with nothing lost or left at .a.__e
    And neither the lookup nor the sweep fails
    And E's record is removed once

  Scenario: Two lookups reach an expired enrollment at once
    Given @bob's enrollment E has expired
    When two lookups of E's data arrive together
    Then E's data ends up at .d.__e once
    And both are told public:_apsk.E.a.__e@bob does not exist
