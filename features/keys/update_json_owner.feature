Feature: update:json applies update's owner rule to the atKey it carries

  An update:json document names its record in atKey, and may name the
  record's owner separately in sharedBy. Either way the owner must be this
  atSign, as update requires: a document whose atKey ends in another atSign
  is refused with AT0016, as update:<key>@<another atSign> is, and nothing is
  stored. Owners are compared folded.

  Races: the check reads only the request.
  Replay: a refused request changes nothing, so a resent one is refused again.
  DoS: the check reads the atKey once, in time linear in its length, and
  stores nothing.
  Forgery and impersonation: no own client stores a record that names
  another atSign as its owner.

  Scenario Outline: update:json refuses an atKey another atSign owns
    Given @alice's client authenticated by <auth>
    When it sends update:json with atKey <atKey>
    Then it is refused with AT0016
    And nothing is stored

    Examples:
      | auth                   | atKey                          |
      | cram                   | x.new.enrollments.__manage@bob |
      | apkam as enrollment e1 | x.e1.a.__e@bob                 |
      | apkam as enrollment e1 | x.wavi@bob                     |
      | apkam as enrollment e1 | public:y.wavi@bob              |
      | apkam as enrollment e1 | @alice:z.wavi@bob              |

  Scenario Outline: update:json stores a record this atSign owns
    Given @alice's client authenticated by apkam as enrollment e1
    When it sends update:json with atKey <atKey>
    Then it succeeds

    Examples:
      | atKey          |
      | x.wavi@alice   |
      | x.wavi@ALICE   |
