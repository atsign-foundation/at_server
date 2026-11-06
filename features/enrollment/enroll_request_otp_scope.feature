Feature: An enroll:request presenting an OTP asks only for namespaces the OTP covers

  An OTP records the namespaces of the enrollment that issued it with
  otp:get. An unauthenticated enroll:request presenting that OTP may ask only
  for namespaces those cover, as namespace access resolves them: a held
  namespace covers itself and every namespace ending in "." followed by it,
  and * covers any namespace but __manage, each at the access held or less,
  so rw covers r. * and __manage themselves must be held literally. A
  namespace is covered when * or any held namespace it ends with grants the
  access asked for. Namespaces are compared as the keystore folds key names.
  A request asking for more is refused with AT0009. The SPP, an OTP issued
  over CRAM, and an OTP stored before OTPs recorded namespaces carry none,
  and do not limit the request.

  Privilege: an OTP passes on at most what the enrollment that issued it
  held, so a narrowly scoped __manage enrollment cannot hand out a request
  for more.
  Forgery and impersonation: the namespaces compared are the ones the
  atServer stored with the OTP, never ones the request supplies.
  Replay: the OTP is spent before its namespaces are compared, so a refused
  request cannot be resent asking for less to learn what the OTP covers.
  Races: the OTP is claimed as before; the comparison reads no shared state.
  DoS: the comparison is the requested namespaces times the OTP's, which the
  enroll params and enrollment record size limits bound.
  Refusal: a refused request stores no enrollment record and no notification
  for an approver, and its OTP is spent.

  Scenario: An OTP admits a request within its namespaces
    Given @alice's atServer holds OTP P, issued with {"wavi":"rw","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"wavi":"r"}
    Then the request is accepted as pending

  Scenario: An OTP refuses a namespace it does not hold, and is spent
    Given @alice's atServer holds OTP P, issued with {"wavi":"rw","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"buzz":"rw"}
    Then the request is refused with AT0009
    And an enroll:request with passcode P for {"wavi":"r"} is refused as an invalid OTP

  Scenario: An OTP refuses more access than it holds
    Given @alice's atServer holds OTP P, issued with {"*":"r","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"wavi":"rw"}
    Then the request is refused with AT0009

  Scenario: An OTP holding * does not cover __manage
    Given @alice's atServer holds OTP P, issued with {"*":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"__manage":"r"}
    Then the request is refused with AT0009

  Scenario: An OTP refuses more access on __manage than it holds
    Given @alice's atServer holds OTP P, issued with {"wavi":"rw","__manage":"r"}
    When an unauthenticated connection sends enroll:request with passcode P for {"__manage":"rw"}
    Then the request is refused with AT0009

  Scenario: An OTP refuses more access on * than it holds
    Given @alice's atServer holds OTP P, issued with {"*":"r","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"*":"rw"}
    Then the request is refused with AT0009

  Scenario: An OTP's namespaces are compared as the keystore folds them
    Given @alice's atServer holds OTP P, issued with {"Wavi":"rw","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"wavi":"rw"}
    Then the request is accepted as pending

  Scenario: An OTP covers a namespace ending in one it holds
    Given @alice's atServer holds OTP P, issued with {"wavi":"rw","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"x.wavi":"rw"}
    Then the request is accepted as pending

  Scenario: An OTP does not cover a namespace ending in its letters without a dot
    Given @alice's atServer holds OTP P, issued with {"wavi":"rw","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"xwavi":"rw"}
    Then the request is refused with AT0009

  Scenario: An OTP holding * covers a namespace it also holds more narrowly
    Given @alice's atServer holds OTP P, issued with {"*":"rw","wavi":"r","__manage":"rw"}
    When an unauthenticated connection sends enroll:request with passcode P for {"x.wavi":"rw"}
    Then the request is accepted as pending

  Scenario Outline: A passcode carrying no namespaces does not limit the request
    Given <passcode>
    When an unauthenticated connection sends enroll:request with that passcode for {"buzz":"rw"}
    Then the request is accepted as pending

    Examples:
      | passcode                                                        |
      | the SPP, set with otp:put                                       |
      | an OTP issued with otp:get over CRAM                            |
      | an OTP stored before OTPs recorded namespaces, as a bare value  |