Feature: An update of a key whose name starts with meta is stored

  update:meta: updates a key's metadata alone; any other update whose key
  merely begins with "meta" is an ordinary update, stored like any other.

  Races, replay and DoS: unchanged; this changes only which handler takes
  the command.
  Forgery and impersonation: unchanged; the update is authorized as any
  update is.

  Scenario: An update of a key whose name starts with meta is stored
    Given a connection to @alice's atServer that has authenticated with pkam
    When it sends update:metadata.wavi@alice v
    Then the atServer answers data:<commit id>
    And llookup:metadata.wavi@alice answers v
