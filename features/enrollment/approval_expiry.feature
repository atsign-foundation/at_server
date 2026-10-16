Feature: An approved enrollment expires no later than the enrollment that approved it

  When an enrollment approves another over its own connection, the atServer
  caps the approved enrollment's expiry at the approver's own, at the moment
  of approval. The approval is never refused for it. An earlier expiry the
  request asked for is kept. No value and zero both ask for no expiry, and
  are capped like any other. So is a pending record holding an expiry
  outside the range a request may ask for, negative or too long for a
  deadline to be computed from it. An approval over a CRAM connection, or by
  an enrollment that never expires, caps nothing.
  An enrollment a CRAM connection requests is the atSign's root: it never
  expires, whatever expiry it asks for, and its apkamKeysExpiryInMillis is 0.

  The approver's expiry is read from its stored record, which is where a
  bounded replacement's deadline is kept. After approval,
  apkamKeysExpiryInMillis is the term granted and expiresAt the moment it
  ends. The cap is applied when an enrollment is approved and at no other
  time.

  Whether to approve is the approver's decision, so every place an approver
  reads a pending request shows the expiry it asks for, as
  apkamKeysExpiryInMillis, 0 meaning none: enroll:list, enroll:fetch and the
  new.enrollments.__manage notification.

  Races: the approval reads the approver's expiry inside the atSign's
  enrollment-mutation critical section, so a revoke or replacement of the
  approver lands wholly before or after it. An approver whose expiry has
  passed is refused as not authorized. One whose expiry passes in the moment
  between that check and the cap, inside the same critical section, caps the
  approved enrollment at a moment already past, so it is expired from the
  start.
  Replay: an approve acts only on a pending enrollment, so a resent approve
  is refused and changes no expiry.
  DoS: the cap reads one record inside a critical section the approval
  already holds; no input grows the work.
  Forgery and impersonation: the expiry that caps is that of the enrollment
  the connection authenticated as, never one the request names. The
  notification only announces; the approval acts on the stored request,
  which enroll:list and enroll:fetch read.

  Scenario Outline: An approval caps the approved enrollment's expiry at the approver's
    Given @alice's enrollment A holds __manage and expires at T
    And enrollment B is pending, asking for <requested>
    When A approves B
    Then B is approved
    And B's record expires at <expiry>
    And the encryption keys stored for B on approval expire at <expiry>
    And the approve response carries expiresAt <expiry>
    And enroll:list and enroll:fetch show B's apkamKeysExpiryInMillis as the time from its approval to <expiry>

    Examples:
      | requested                       | expiry                 |
      | no expiry                       | T                      |
      | an apkamKeysExpiryInMillis of 0 | T                      |
      | an expiry later than T          | T                      |
      | an expiry earlier than T        | the expiry B asked for |

  Scenario Outline: A pending record holding an expiry outside the request bound is capped at the approver's
    Given @alice's enrollment A holds __manage and expires at T
    And enrollment B is pending, and its record holds <stored>
    When A approves B
    Then B is approved
    And B's record expires at T
    And the encryption keys stored for B on approval expire at T
    And the approve response carries expiresAt T
    And enroll:list and enroll:fetch show B's apkamKeysExpiryInMillis as the time from its approval to T

    Examples:
      | stored                                                   |
      | a negative expiry                                        |
      | an expiry too long for a deadline to be computed from it |

  Scenario: An approver whose record holds a deadline caps at that deadline
    Given @alice's enrollment A holds __manage, asked for no expiry, and its record expires at T because it replaced an enrollment that expires at T
    And enrollment B is pending, asking for no expiry
    When A approves B
    Then B's record expires at T

  Scenario: A retrofit successor expires no later than its predecessor
    Given @alice's enrollment P's record expires at T
    When P requests its successor S, asking for a term that ends just before T, counted from the request
    Then S's record expires no later than T

  Scenario: An approver that never expires caps nothing
    Given @alice's enrollment A holds __manage and never expires
    And enrollment B is pending, asking for no expiry
    When A approves B
    Then B never expires
    And the approve response carries expiresAt null

  Scenario: An approval over a CRAM connection caps nothing
    Given enrollment B is pending, asking for no expiry
    When a CRAM-authenticated connection approves B
    Then B never expires

  Scenario: An enrollment a CRAM connection requests never expires, and says so
    Given a CRAM-authenticated connection to @alice's atServer
    When it sends enroll:request asking for an apkamKeysExpiryInMillis of 3600000
    Then the enrollment is approved and never expires
    And enroll:list and enroll:fetch show its apkamKeysExpiryInMillis as 0

  Scenario: An enrollment capped at its approver's expiry ends with it
    Given A expires at T and approved B, which asked for no expiry
    When T passes
    Then B's pkam is refused with AT0028

  Scenario: An approver whose expiry has passed cannot approve
    Given @alice's enrollment A holds __manage and its expiry has passed, though its record is not yet removed
    When A approves pending enrollment B
    Then the approve is refused with AT0009
    And B is still pending

  Scenario: A capped enrollment keeps its expiry through revoke and unrevoke
    Given A approved B, capping it at T
    When B is revoked and then unrevoked
    Then B's record still expires at T

  Scenario: An enrollment moved onto a successor keeps its own expiry
    Given @alice's enrollment P expires at T and approved C, capping it at T
    And P's successor S asked for a term that ends at T2, before T
    When S authenticates for the first time and C moves onto S
    Then C's record still expires at T

  Scenario Outline: An approver sees the expiry a pending request asks for
    Given enrollment B is pending, asking for <requested>
    When an enrollment holding __manage reads B through <read>
    Then it sees apkamKeysExpiryInMillis <value>

    Examples:
      | requested           | read                                      | value   |
      | an expiry of 1 hour | enroll:list                               | 3600000 |
      | an expiry of 1 hour | enroll:fetch                              | 3600000 |
      | an expiry of 1 hour | the new.enrollments.__manage notification | 3600000 |
      | no expiry           | enroll:list                               | 0       |
      | no expiry           | enroll:fetch                              | 0       |
      | no expiry           | the new.enrollments.__manage notification | 0       |
