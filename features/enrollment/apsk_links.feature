Feature: Links vouch for an enrollment's client data signing keys, one per key

  Each enrollment publishes the keys it signs with at
  public:_apsk.<enrollmentId>.a.__e@<atSign>, in the list form or as one
  bare RSA key. A link vouches for one of those keys. The atServer keeps an
  enrollment's links in one map in that record's appMetadata, apskLinks,
  keyed by kid, and enroll:link is the only way to write one:

    enroll:link:{"enrollmentId":"<target>","links":{"<kid>":{"link":<link>,"expect":<link or null>}}}

  A link's payload names the target enrollment and the kid, alg and pub of
  the key it vouches for, and a link stays on a key only while the record
  lists that alg and pub under its kid. A chain link carries its payload
  base64url-encoded and a root link as a JSON object. The atServer checks
  that structure and never a signature; whoever reads a link verifies it. A
  bare _apsk value is one rsa2048 key whose kid is the first 8 bytes,
  hex-encoded, of the SHA-256 of the decoded key, as every other kid is
  derived. A key that is the enrollment's authentication key, the
  apkamPublicKey its record holds, takes no link and keeps none, whether the
  record carries it bare or in the list form. A key takes a link only when
  its public key is spelt as clients write it, in padded standard base64.

  Races: enroll:link, and every other write of an approved enrollment's
  _apsk record a client can send, a delete included, run under the atSign's
  enrollment-mutation lock, so each lands wholly before or after another. A
  link replaces the stored one only when the request's expect equals it as
  JSON, so two writers of one key's link cannot lose each other's write.
  Replay: a link names its enrollment and key, so it can be stored only on
  that key; re-sending a stored link with its own expect is refused unless
  the stored link is still the one expected.
  DoS: only the target or a caller passing the approve gate can write; one
  link per key the record advertises, each at most 16 KiB encoded, and both
  the whole call and the _apsk record with all its links within the 500 KiB
  enrollment-record limit, as is every other write of that record that
  keeps links.
  Forgery and impersonation: the atServer stores a link without checking
  its signature, and a stored link is a claim the reader checks. The right
  to write one is the right to approve or revoke the target.

  Scenario: enroll:link admits only the target or a caller that could approve it
    Given enrollment C without __manage, and enrollment D holding __manage but not every namespace B holds at B's access
    When C or D calls enroll:link for B
    Then the atServer refuses it, and nothing is written
    And B calling enroll:link on its own keys is admitted without __manage
    And a caller passing the approve gate is admitted
    And so is a CRAM connection, as for enroll:approve

  Scenario: enroll:link checks structure, and writes all or nothing
    Given B approved, its _apsk advertising K1 and K2
    When one call carries a well-formed link for K1 and any of: a link for an unadvertised K9, or for a key not spelt in padded standard base64; a link whose payload names another enrollment, or another kid, alg or public key; a link over 16 KiB; or the call, or B's _apsk record with every link it would then hold, is over the 500 KiB limit
    Then the whole call is refused, naming what failed, and K1's link is not written either
    And a call for an enrollment that isn't approved is refused
    And a call carrying well-formed links for K1 and K2 writes both

  Scenario: enroll:link and enroll:update leave an immutable _apsk record unchanged
    Given B's _apsk record is immutable
    When enroll:link links one of its keys, or an enroll:update republishes it
    Then the atServer refuses it, and nothing is written
    And an approval publishing over an immutable _apsk record leaves that record as it stands

  Scenario: a link replaces only the link its writer found
    Given key K1 on B carries a link L1
    When a voucher sends a new link for K1 with a copy of the link it found on K1, and that copy is "none" or a link other than L1
    Then the atServer refuses the call, and L1 stays on K1
    And when the copy it sends is L1, its new link replaces L1
    And when two vouchers each find no link on K1 and each send a new link with the copy "none", the first to arrive is written and the second is refused

  Scenario: any other write of B's _apsk keeps B's links
    Given B's _apsk record carries links for K1 and K2
    When B's _apsk is written any way other than enroll:link: an enroll:update republish that adds K3, or a put of the record, including one that still sends the old version 1 link fields
    Then the links for K1 and K2 are still on the record afterwards, unchanged, whatever that write sent
    And when the new value no longer lists K2 at all, K2's link is removed in the same write
    And when an enroll:link for K1 and a republish that removes K1 arrive together, the atServer handles one and then the other, so afterwards K1 has no link and no other link has been lost
    And an enroll:update republish that changes the value stores no dataSignature over the value it replaces

  Scenario: a link stays on a key only while the record lists the alg and public key it names
    Given B's _apsk lists K1, and K1 carries a link naming K1's alg and public key
    When any write of B's _apsk lists another alg or public key under K1's kid
    Then K1's link is removed in the same write, as for a key the record no longer lists
    And a write that lists K1's alg and public key as before, whatever its status, keeps K1's link

  Scenario: a write that removes B's last link leaves no appMetadata the atServer made
    Given B's _apsk record whose appMetadata holds only its links, under the providerId the atServer gives
    When a write of B's _apsk removes its last link
    Then the record carries no appMetadata
    And a record whose appMetadata names another providerId or holds anything else keeps it, as does a client's own appMetadata on a record that carried no links

  Scenario: every write of B's _apsk keeps the record and its links within 500 KiB
    Given B's _apsk record carries links
    When an enroll:update republish, a put or an update:meta would take the record, its value and appMetadata with the links it keeps, over the 500 KiB enrollment-record limit
    Then the atServer refuses the write, and the record is unchanged
    And after a refused enroll:update, B's enrollment record is unchanged too
    And a record that keeps no links is not held to that limit

  Scenario: an enrollment's authentication key takes no links
    Given B holding no client data signing key of its own, so its _apsk is its APKAM authentication key, published bare or listed alone in the list form
    When enroll:link is asked to link that key
    Then the atServer refuses it, since the key is the one B's enrollment record holds as its apkamPublicKey, and nothing is written

  Scenario: an enroll:update cannot make B's client data signing key its authentication key
    Given B's enrollment and its _apsk
    When an enroll:update by B would leave K1 both as B's apkamPublicKey and listed in B's _apsk beside another key, or carrying a link, whether it installs K1, republishes the _apsk, or both
    Then the atServer refuses the update, naming K1, and nothing is written
    And an update that leaves K1 as the only key B's _apsk lists, with no link, is accepted, as for an enrollment holding no client data signing key of its own

  Scenario: every write of B's _apsk lists each kid once, each with a kid, alg and pub
    Given B's enrollment and its _apsk
    When an enroll:update by B, through apsk or apskLegacy, or a put or an update:meta of B's _apsk, would leave it listing one kid twice, or an entry without a string kid, alg and pub
    Then the atServer refuses the write, naming the entry, and nothing is written
    And enroll:link refuses to link a kid the record lists twice

  Scenario: an enroll:request lists its authentication key in its _apsk only alone
    Given a request whose apsk, or apskLegacy in the list form, lists its apkamPublicKey beside another key
    When it is sent, whether for approval or over CRAM
    Then the atServer refuses it, naming the key, and nothing is written
    And a request whose apsk lists one kid twice is refused, naming it, before its OTP is spent
    And a request whose apsk lists its apkamPublicKey alone, or not at all, is accepted

  Scenario: an enrollment's authentication key is listed only alone, and keeps no link, through any write
    Given B's _apsk record carries links for K1 and K2, and B's enrollment record holds K1's public key as its apkamPublicKey
    When a put or an update:meta of B's _apsk would leave K1 listed beside K2
    Then the atServer refuses it, naming K1, and the record is unchanged
    And a put that lists K1 alone keeps no link on it
    And an enroll:link for another key removes the link stored on K1 in the same write

  Scenario: a rotation of primary's key keeps no link on it
    Given primary's _apsk lists K1 and K2, each carrying a link
    When a CRAM update of at_pkam_publickey would make K1's public key primary's authentication key while K1 is listed beside K2 or carries a link
    Then the atServer refuses it, naming K1, and primary is unchanged
    And when a legacy pkam: absorbs a flat key, or the startup migration mints primary, onto K1's public key, K1's link is removed in the same act and K2's link stays

  Scenario: an unrevoked enrollment's _apsk keeps only the links a write of it keeps
    Given B revoked, its _apsk record moved aside, and links stored on that record since
    When B is unrevoked and the record moves back
    Then it keeps only the links a write of it would keep: none for a kid it does not list, and none that names another kid, alg or public key
    And an immutable record moves back as it stands

  Scenario: the atServer reads an _apsk value trimmed, as a client does
    Given an _apsk value with whitespace before or after it
    When it is written or linked
    Then the atServer reads its keys from the trimmed value, as a client does, and every rule above applies to them

  Scenario: a bare RSA client data signing key is linked like a listed one
    Given B on the pqReady posture, authenticating with ML-DSA-65, whose _apsk is the RSA-2048 client data signing key it minted, published bare
    When enroll:link links that key
    Then the atServer treats the bare value as one rsa2048 entry, whose kid it derives from the key the way every other kid is derived, and the link is written
    And when B lists that key in the list form beside an ML-DSA-65 key, retiring the RSA one, the RSA key keeps the same kid and keeps its link

  Scenario: an enroll operation the atServer does not support is refused
    Given an enroll operation this atServer does not support
    When a client sends it
    Then the atServer refuses it, and nothing is written
