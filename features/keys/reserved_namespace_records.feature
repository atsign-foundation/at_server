Feature: An atSign's own clients change reserved-namespace records only through the verbs that own them

  A record uses a reserved namespace by the rule notifications follow: its
  key, without any public: or cached: prefix, has a last dot-separated
  segment that begins with "__", or a dot-separated segment that, folded,
  is __e or begins with one of __manage, __atserver, __global, __private,
  __otp and __config.

  Such a record of this atSign, public or not, changes only through the verb
  that owns it, such as enroll:, otp:, keys: or config:, or by the atServer
  itself. An atSign's own client, whether authenticated by cram, pkam or
  apkam, that sends update, update:meta or delete for one, on its own or in
  a batch, is refused with AT0009, keeps its connection, and the record is
  unchanged. The exception is the connection's own per-enrollment namespace,
  <enrollmentId>.a.__e, whose records of this atSign that enrollment may
  change; a pkam connection's enrollment is primary, and so is a cram
  connection's until an enroll:request on it, after which it is the
  enrollment that request created. A record in a per-enrollment
  namespace is never for another atSign: an enrollment's records there are
  public, shared with this atSign, or have no scope, so an update or
  update:meta of one shared with another atSign is refused with AT0009. A
  delete of one is allowed, so any that exist can be removed.

  Reading is unchanged, with one exception: scan, lookup and llookup show a
  client what its enrollment may read, but a stored passcode, in __otp or at
  private:spp, is read only through otp:, so a lookup or llookup of one is
  refused with AT0009 whichever way the client authenticated.

  Races: each check reads only the request and the connection's enrollment,
  which the verb already reads.
  Replay: a refused request changes nothing, so a resent one is refused again.
  DoS: each check compares the key's segments, in time linear in the key's
  length, and stores nothing.
  Forgery and impersonation: no own client can write a record that enroll:,
  otp:, keys: or the atServer vouches for, such as an enrollment, a passcode,
  conveyed keys or an event; no grant of * reads a stored passcode; and a
  cached copy of another atSign's record is never one of this atSign's
  enrollments.

  Scenario Outline: An atSign's own client may not change a record in a reserved namespace
    Given @alice's client authenticated by <auth>
    When it sends <command>
    Then it is refused with AT0009
    And the record is unchanged

    Examples:
      | auth                                | command                                                            |
      | cram                                | update:e1.new.enrollments.__manage@alice {"appName":"x"}           |
      | cram                                | update:e1.default_enc_private_key.__manage@alice k                 |
      | pkam                                | update:x.__global@alice v                                          |
      | apkam as an enrollment holding *:rw | update:x.__private@alice v                                         |
      | apkam as an enrollment holding *:rw | update:x.__config@alice v                                          |
      | apkam as an enrollment holding *:rw | update:public:x.__foo@alice v                                      |
      | apkam as an enrollment holding *:rw | update:@bob:x.__global@alice v                                     |
      | apkam as an enrollment holding *:rw | update:meta:x.__global@alice:ttl:1000                              |
      | apkam as an enrollment holding *:rw | delete:x.__global@alice                                            |
      | apkam as enrollment e1              | update:x.e2.a.__e@alice v                                          |
      | cram                                | update:x.e2.a.__e@alice v                                          |
      | cram                                | update:x.xprimary.a.__e@alice v                                    |
      | cram                                | update:x.primary.a.__e.__global@alice v                            |
      | apkam as enrollment e9 holding *:rw | update:x.e9.a.__e.__private@alice v                                |
      | apkam as enrollment e1              | update:json:{"atKey":"x.e1.a.__e@bob","value":"v"}                 |
      | cram, after an enroll:request on it | update:public:_apsk.primary.a.__e@alice v                          |
      | cram                                | delete:1700000000000000.events.__atserver@alice                    |
      | cram                                | update:json:{"atKey":"x.new.enrollments.__manage@bob","value":"v"} |

  Scenario: An atSign's own client may not change a record in a reserved namespace inside a batch
    Given @alice's client authenticated by apkam as an enrollment holding *:rw
    When it sends a batch of update:x.__global@alice v and update:x.wavi@alice v
    Then the entry for x.__global is answered AT0009 and x.__global is unchanged
    And the entry for x.wavi succeeds

  Scenario Outline: An enrollment changes records in its own per-enrollment namespace
    Given @alice's client authenticated by <auth>
    When it sends <command>
    Then it succeeds

    Examples:
      | auth                                                       | command                                   |
      | apkam as enrollment e1                                     | update:__ckcur.bob.wavi.e1.a.__e@alice v  |
      | apkam as enrollment e1                                     | delete:__ckcur.bob.wavi.e1.a.__e@alice    |
      | pkam, as enrollment primary                                | update:public:_apsk.primary.a.__e@alice v |
      | cram, as enrollment primary                                | update:public:_apsk.primary.a.__e@alice v |
      | cram, as enrollment n1 after its enroll:request created n1 | update:public:_apsk.n1.a.__e@alice v      |
      | apkam as enrollment e1                                     | update:@alice:x.e1.a.__e@alice v          |

  Scenario Outline: An enrollment's records in its own per-enrollment namespace are never for another atSign
    Given @alice's client authenticated by apkam as enrollment e1
    When it sends <command>
    Then it is refused with AT0009
    And the record is unchanged

    Examples:
      | command                                    |
      | update:@bob:x.e1.a.__e@alice v             |
      | update:meta:@bob:x.e1.a.__e@alice:ttl:1000 |

  Scenario Outline: A stored passcode is read only through otp:
    Given @alice's atServer holds a semi-permanent passcode at <record>
    And @alice's client authenticated by <auth>
    When it sends <command>
    Then it is refused with AT0009
    And the answer does not hold the passcode

    Examples:
      | auth                               | record                  | command                            |
      | cram                               | private:spp.__otp@alice | llookup:private:spp.__otp@alice    |
      | apkam as an enrollment holding *:r | private:spp.__otp@alice | llookup:private:spp.__otp@alice    |
      | cram                               | private:spp.__otp@alice | lookup:private:spp.__otp@alice     |
      | apkam as an enrollment holding *:r | private:spp.__otp@alice | lookup:all:private:spp.__otp@alice |
      | apkam as an enrollment holding *:r | private:spp@alice       | llookup:private:spp@alice          |
      | cram                               | private:spp@alice       | lookup:private:spp@alice           |
      | cram                               | private:spp@alice       | llookup:PRIVATE:SPP@alice          |
      | apkam as an enrollment holding *:r | private:spp.__otp@alice | llookup:private:spp.__OTP@alice    |

  Scenario: An atSign's own client still reads what its enrollment may read in a reserved namespace
    Given @alice's client authenticated by apkam as an enrollment holding *:r
    When it sends llookup:1700000000000000.events.__atserver@alice
    Then it gets the record's value

  Scenario: A cached copy of another atSign's record is never one of this atSign's enrollments
    Given @alice's atServer holds cached:@alice:x.new.enrollments.__manage@bob, holding an approved enrollment of *:rw and __manage:rw
    When @alice's atServer lists its enrollments, for enroll:list, enroll:listns or its own checks
    Then that record is not among them
