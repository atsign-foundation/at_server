Feature: An enrollment request's key expiry is bounded

  An enroll:request's apkamKeysExpiryInMillis, when present, must be a whole
  number of milliseconds from 0 to 3155760000000, which is 36,525 days. Zero
  still means the keys never expire. A request outside that range, or whose
  expiry is not a whole number, is refused with AT0022, and nothing is stored.

  Races: the check reads only the request, before the enroll handler reads or
  writes anything.
  Replay: nothing is written or spent before the check.
  DoS: the check compares one number, before any lookup or write.
  Forgery and impersonation: the check decides nothing about who is asking,
  and a refused request stores nothing.

  Scenario Outline: A request asking for a key expiry outside the bound is refused
    Given a new device holds an OTP for @alice
    When it sends enroll:request with apkamKeysExpiryInMillis <expiry>
    Then it is refused with AT0022: apkamKeysExpiryInMillis must be a whole number of milliseconds from 0 to 3155760000000
    And @alice has no new pending enrollment

    Examples:
      | expiry            |
      | 3155760000001     |
      | -1                |
      | 18446744160109551 |
      | 1.5               |
      | "3600000"         |

  Scenario Outline: A request asking for a key expiry within the bound is pending with that expiry
    Given a new device holds an OTP for @alice
    When it sends enroll:request with apkamKeysExpiryInMillis <expiry>
    Then the request is pending
    And enroll:list reports its apkamKeysExpiryInMillis as <expiry>

    Examples:
      | expiry        |
      | 3155760000000 |
      | 1             |
      | 0             |

  Scenario: A self-enrollment asking for a key expiry outside the bound is refused
    Given an approved enrollment of @alice, authenticated as itself
    When it sends enroll:request for its successor with apkamKeysExpiryInMillis -1
    Then it is refused with AT0022: apkamKeysExpiryInMillis must be a whole number of milliseconds from 0 to 3155760000000

  Scenario: An approver that never expires approves the longest key expiry
    Given a pending request with apkamKeysExpiryInMillis 3155760000000
    When @alice's primary enrollment, which never expires, approves it
    Then it is approved, and expires 36,525 days after its approval
