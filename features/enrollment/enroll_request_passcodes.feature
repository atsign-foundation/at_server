Feature: An enroll:request passcode is accepted only as the SPP or as an OTP the atServer issued

  An unauthenticated enroll:request carries a passcode. The atServer accepts
  it when it is the SPP's value, or when an OTP the atServer issued with
  otp:get is stored under it in the __otp namespace. A passcode is read as an
  OTP only when it has the shape otp:get issues, six or more letters, digits
  or underscores, and only from that OTP's own record, so an issued OTP in
  another spelling is not read as that OTP. No record outside the __otp
  namespace is read as an OTP. An SPP stored in the namespace-less form older
  atServers used still counts as the SPP. A refused passcode changes no
  record.

  Races: an OTP is claimed by its folded key with no await between checking
  and claiming it, so of two otherwise valid requests presenting one OTP at
  once, exactly one is admitted.
  Replay: a claimed OTP is removed, so a resent request is refused. The SPP is
  reusable by design until it expires or is deleted.
  DoS: a refused passcode is answered after the existing growing delay and
  changes no record; the check makes at most three keystore lookups.
  Forgery and impersonation: only the SPP's records and the OTPs the atServer
  stored in the __otp namespace are read as passcodes; a request cannot make
  any other record count as one.

  Scenario: An OTP the atServer issued admits one enroll:request
    Given @alice's atServer issued OTP P with otp:get
    When an unauthenticated connection sends enroll:request with passcode P
    Then the request is accepted as pending
    And a second enroll:request with passcode P is refused as an invalid OTP

  @race
  Scenario: Two enroll:requests presenting one OTP at once admit only one
    Given @alice's atServer issued OTP P with otp:get
    When two unauthenticated connections send otherwise valid enroll:requests with passcode P at the same moment
    Then exactly one of the requests is accepted as pending
    And the other is refused as an invalid OTP

  Scenario Outline: An issued OTP in another spelling is refused
    Given @alice's atServer issued OTP P with otp:get
    When an unauthenticated connection sends enroll:request with passcode <spelling>
    Then the request is refused as an invalid OTP
    And an enroll:request with passcode P is still accepted as pending

    Examples:
      | spelling                 |
      | P with a leading space   |
      | P with a space inside it |

  Scenario: A record outside the __otp namespace is never read as an OTP
    Given @alice's atServer holds private:abc123@alice, whose value is abc123
    When an unauthenticated connection sends enroll:request with passcode abc123
    Then the request is refused as an invalid OTP
    And private:abc123@alice still holds abc123

  Scenario: An SPP stored in the namespace-less form still counts as the SPP
    Given @alice's atServer holds private:spp@alice, whose value is ABC123, and no SPP in the __otp namespace
    When an unauthenticated connection sends enroll:request with passcode ABC123
    Then the request is accepted as pending
