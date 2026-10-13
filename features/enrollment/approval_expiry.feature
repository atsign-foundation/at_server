Feature: An approved enrollment expires no later than the enrollment that approved it

  When an enrollment approves another over its own connection, the atServer
  caps the approved enrollment's expiry at the approver's own, at the moment
  of approval. The approval is never refused for it. An earlier expiry the
  request asked for is kept. No value, zero and a negative value all ask for
  no expiry, and are capped like any other. An approval over a CRAM
  connection, or by an enrollment that never expires, caps nothing.

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
  approver lands wholly before or after it. An approver whose expiry passes
  while its approval is in flight caps the approved enrollment at a moment
  already past, so it is expired from the start.
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

    Examples:
      | requested                       | expiry                 |
      | no expiry                       | T                      |
      | an apkamKeysExpiryInMillis of 0 | T                      |
      | a negative expiry               | T                      |
      | an expiry later than T          | T                      |
      | an expiry earlier than T        | the expiry B asked for |

  Scenario: An approver whose record holds a deadline caps at that deadline
    Given @alice's enrollment A holds __manage, asked for no expiry, and its record expires at T because it replaced an enrollment that expires at T
    And enrollment B is pending, asking for no expiry
    When A approves B
    Then B's record expires at T

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

  Scenario: An enrollment capped at its approver's expiry ends with it
    Given A expires at T and approved B, which asked for no expiry
    When T passes
    Then B's pkam is refused with AT0028

  Scenario: A capped enrollment keeps its expiry through revoke and unrevoke
    Given A approved B, capping it at T
    When B is revoked and then unrevoked
    Then B's record still expires at T

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
