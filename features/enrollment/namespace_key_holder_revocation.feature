Feature: enroll:infons reports when an enrollment that may have held a namespace key was last revoked

  enroll:infons:<namespace> answers lastKeyHolderRevokedAt beside
  lastRevokedAt: the most recent moment an enrollment holding <namespace>,
  and that may have held a namespace private, was revoked. An enrollment
  may have held one when its record has ever carried a key package, or when
  a connection authenticated as it has ever written a namespace-key
  advertisement, public:__nskey.<namespace>@<atSign>, for any namespace.
  The first of either marks the enrollment's record, and nothing clears the
  mark. Each revocation event records the revoked enrollment's mark at that
  moment.

  lastKeyHolderRevokedAt is derived as lastRevokedAt is, from only the
  revocation events whose mark is set and the events recorded before the
  mark existed. Un-revoking an enrollment withdraws its revocation from
  both, so both can move backwards. Both keys are always present, null when
  nothing qualifies. lastRevokedAt counts every revocation, a supersession
  included.

  A record carries a key package when its metadata holds a keyPackage
  entry, and a record written before the mark existed is marked if it holds
  one, even one set to null: enroll:update merges metadata entry by entry
  and never removes one, so a null entry is a key package updated away.

  An advertisement written with update:, update:json or a batch: entry, as
  sync sends it, marks the enrollment the connection authenticated as
  before the advertisement is stored. A legacy pkam: connection
  authenticates as the enrollment primary, and marks it. A connection that
  carries no enrollment id, a CRAM connection before its enroll:request,
  has no record to mark. update:meta cannot change the advertised key and
  marks nothing; neither does a delete.

  An advertisement written before the mark existed does not say who wrote
  it, and nothing marks its writer afterwards: an enrollment that wrote one
  then, and whose record has never carried a key package, is not marked.

  Races: every write of an enrollment record and every revocation runs in
  the atSign's enrollment-mutation critical section. An advertisement write
  marks the enrollment and stores the advertisement inside it, reading the
  enrollment's state there, so a revoke of that enrollment lands wholly
  before the write, which is then refused, or wholly after it, and its
  event records the mark. An enroll:update and a revoke of one enrollment
  land one before the other, and once set the mark stays whatever lands
  next. A revocation event is recorded only for a record read in the same
  critical section, so a record removed by expiry is never revoked and
  never loses a mark to an event.
  Replay: no challenge or nonce is involved. A repeated advertisement write
  marks an enrollment already marked, and a repeated revoke is refused
  because the enrollment is no longer approved.
  DoS: an advertisement write reads one enrollment record and writes it
  only the first time, in the critical section enroll:update already takes;
  enroll:infons reads the revocation history once and derives both answers
  from it.
  Forgery: enrollment records and revocation events live in __manage, which
  no client may update or delete. The mark comes only from what the
  atServer stored or saw a connection write, never from a request field, so
  a client can set its own mark and never clear it.
  Impersonation: the enrollment marked is the one the connection
  authenticated as, never one a request names, and only the atSign's own
  advertisement marks anything.

  Scenario Outline: A revoked enrollment whose record has carried a key package moves lastKeyHolderRevokedAt
    Given E3 has rw on "app", and its record carried a key package <how>
    When E3 is revoked
    Then lastKeyHolderRevokedAt for "app" is the moment of that revocation

    Examples:
      | how                        |
      | from its enroll:request    |
      | from its own enroll:update |

  Scenario Outline: Every kind of revocation of an enrollment that may have held a namespace key moves it
    Given <enrollment> has rw on "app"
    When <enrollment> is <revoked>
    Then lastKeyHolderRevokedAt for "app" is the moment of that revocation

    Examples:
      | enrollment                                                          | revoked                                                       |
      | E3, whose record carried a key package                              | revoked by the cascade from revoking the one that approved it |
      | E2, over whose connection a namespace-key advertisement was written | superseded by its retrofit's first authentication             |

  Scenario: An enrollment that updated its key package away before revocation still moves it
    Given E3 has rw on "app", and its record carried a key package
    And E3 then set its keyPackage to null with enroll:update
    When E3 is revoked
    Then lastKeyHolderRevokedAt for "app" is the moment of that revocation

  Scenario Outline: A record that carried a key package before the mark existed counts as marked
    Given E3 has rw on "app", and its record was written before the mark existed with metadata <metadata>
    When E3 is revoked
    Then lastKeyHolderRevokedAt for "app" is the moment of that revocation

    Examples:
      | metadata                        |
      | {"keyPackage": <a key package>} |
      | {"keyPackage": null}            |

  Scenario Outline: A connection that writes a namespace-key advertisement marks its own enrollment
    Given <enrollment> has rw on "app", and its record has never carried a key package
    And public:__nskey.app@alice <before>
    When a <connection> writes public:__nskey.app@alice with <how>
    And <enrollment> is revoked
    Then lastKeyHolderRevokedAt for "app" is the moment of that revocation

    Examples:
      | enrollment | connection                     | before                                   | how                              |
      | E4         | connection authenticated as E4 | does not exist                           | update:                          |
      | primary    | legacy pkam: connection        | does not exist                           | update:                          |
      | E4         | connection authenticated as E4 | holds a key another enrollment published | update:                          |
      | E4         | connection authenticated as E4 | does not exist                           | update:json                      |
      | E4         | connection authenticated as E4 | does not exist                           | a batch: entry, as sync sends it |

  @impersonation
  Scenario: Writing a namespace-key advertisement marks only the writing connection's own enrollment
    Given E4 and E5 have rw on "app", and neither record has ever carried a key package
    When a connection authenticated as E4 writes public:__nskey.app@alice
    And E5 is revoked
    Then lastKeyHolderRevokedAt for "app" is null
    And lastRevokedAt for "app" is the moment of E5's revocation

  @race
  Scenario: A revoke that lands before an advertisement write is stored refuses the write
    Given E4 has rw on "app", and its record has never carried a key package
    And a connection authenticated as E4 has sent update:public:__nskey.app@alice, and it has been authorised
    When E4 is revoked before the advertisement is stored
    Then the write is refused
    And public:__nskey.app@alice does not exist
    And lastKeyHolderRevokedAt for "app" is null

  Scenario: An enrollment that wrote an advertisement before the mark existed, with no key package, is not marked
    Given E4 has rw on "app", and its record has never carried a key package
    And E4 wrote public:__nskey.app@alice before the mark existed
    When the atServer starts
    And E4 is revoked
    Then lastKeyHolderRevokedAt for "app" is null
    And lastRevokedAt for "app" is the moment of that revocation

  Scenario: A legacy enrollment superseded by its own retrofit does not move it
    Given E2 has rw on "app", its record has never carried a key package, and no connection as E2 has written a namespace-key advertisement
    When its retrofit successor first authenticates and E2 is revoked as superseded
    Then lastKeyHolderRevokedAt for "app" is null
    And lastRevokedAt for "app" is the moment of that supersession

  Scenario: A revocation event recorded before the mark existed counts, conservatively
    Given a revocation event of an enrollment that held "app", recorded with no mark
    When a holder of "app" sends enroll:infons:app
    Then lastKeyHolderRevokedAt is the moment of that event, as lastRevokedAt is

  @forgery
  Scenario Outline: Whether a revocation moves it rests on the record's mark, never on a claim
    Given E3 has rw on "app", and its record carried a key package
    And <claim>
    When E3 is revoked
    Then lastKeyHolderRevokedAt for "app" is the moment of that revocation

    Examples:
      | claim                                                           |
      | the enroll:revoke request carries "keyHolder": false            |
      | E3's own enroll:update set its metadata to {"keyHolder": false} |

  Scenario Outline: Un-revoking the last revoked key holder takes lastKeyHolderRevokedAt back to null
    Given <enrollment> has rw on "app", and has been revoked
    When <enrollment> is un-revoked
    Then lastKeyHolderRevokedAt for "app" is null

    Examples:
      | enrollment                                                                        |
      | E3, whose record carried a key package                                            |
      | E2, whose record has never carried a key package, revoked before the mark existed |

  Scenario: enroll:infons answers lastKeyHolderRevokedAt even when nothing qualifies
    Given E2 has rw on "app", and its record has never carried a key package
    And E2 has been revoked
    When a holder of "app" sends enroll:infons:app
    Then the answer holds lastKeyHolderRevokedAt, and it is null
    And lastRevokedAt is the moment of E2's revocation

  Scenario Outline: lastRevokedAt counts every revocation
    Given <enrollment> has rw on "app"
    When <enrollment> is <revoked>
    Then lastRevokedAt for "app" is the moment of that revocation

    Examples:
      | enrollment                                       | revoked                                           |
      | E3, whose record carried a key package           | revoked                                           |
      | E2, whose record has never carried a key package | revoked                                           |
      | E2, whose record has never carried a key package | superseded by its retrofit's first authentication |
