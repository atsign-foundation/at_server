Feature: Quarantine in open namespaces
  In an open namespace, an atSign that is not admitted may still reach @alice,
  under limits that protect @alice. Its first inbound exchange there makes it
  quarantined. Per namespace and atSign, at most N exchanges are accepted in
  any window of W (defaults 10 and 24 hours), counting notifications and
  lookups alike. A quarantined notification is at most the size cap (default
  15,360 bytes, the whole notify command as received), and it never touches a
  cached key. Each open namespace also bounds how many atSigns it holds in
  quarantine and how many bytes of quarantined notifications. Its holders set
  every one of these, up to a ceiling the atServer operator sets. Quarantined
  notifications are marked, and reach only clients that ask for them. Commands
  spelled "gate:..." are provisional (rules.feature).

  Race: two exchanges at the limit at once accept exactly one, and two
  atSigns seen for the first time competing for the last place admit exactly one
  to quarantine.
  Replay: a repeated notification id is answered "data:success", stored once and
  counted once.
  DoS: every quarantined exchange is bounded per atSign by N, W and the size cap,
  and every open namespace by its two bounds; counts survive a restart.

  Background:
    Given @alice's atSign has the closed default
    And namespace "invitations.chat" on @alice's atServer is open, with the default limits

  Scenario: An accepted notification quarantines an atSign seen for the first time
    Given @dave is in none of the sets of "invitations.chat"
    When @dave's atServer sends "notify:id:1:@alice:inv1.invitations.chat@dave"
    Then @alice's atServer answers "data:success"
    And @dave is quarantined in "invitations.chat"

  Scenario: A lookup quarantines an atSign seen for the first time
    Given @dave is in none of the sets of "invitations.chat"
    And @alice's atServer holds "@dave:profile.invitations.chat@alice"
    When @dave's atServer sends "lookup:profile.invitations.chat@alice"
    Then @alice's atServer answers with the value of "@dave:profile.invitations.chat@alice"
    And @dave is quarantined in "invitations.chat"

  Scenario: A quarantined atSign may look up a key shared with it, and the lookup counts
    Given @chuck is quarantined in "invitations.chat", with 4 exchanges counted in the last 24 hours
    And @alice's atServer holds "@chuck:profile.invitations.chat@alice"
    When @chuck's atServer sends "lookup:profile.invitations.chat@alice"
    Then @alice's atServer answers with the value of "@chuck:profile.invitations.chat@alice"
    And @chuck has 5 exchanges counted in "invitations.chat"

  Scenario: A lookup of a key that is not there counts too
    Given @chuck is quarantined in "invitations.chat", with 4 exchanges counted in the last 24 hours
    When @chuck's atServer sends "lookup:nothing.invitations.chat@alice"
    Then @alice's atServer answers with the key-not-found error, AT0015
    And @chuck has 5 exchanges counted in "invitations.chat"

  Scenario: The eleventh exchange in a window is refused
    Given @chuck is quarantined in "invitations.chat", with 10 exchanges counted in the last 24 hours
    When @chuck's atServer sends "notify:id:11:@alice:inv11.invitations.chat@chuck"
    Then @alice's atServer answers with the quarantine-limit error

  Scenario: The window rolls
    Given @chuck is quarantined in "invitations.chat", with 10 exchanges counted, the oldest 24 hours and 1 minute ago
    When @chuck's atServer sends "notify:id:12:@alice:inv12.invitations.chat@chuck"
    Then @alice's atServer answers "data:success"

  Scenario: Counting is per namespace
    Given namespace "photos" on @alice's atServer is open, with the default limits
    And @chuck is quarantined in "invitations.chat", with 10 exchanges counted in the last 24 hours
    When @chuck's atServer sends "notify:id:13:@alice:pic.photos@chuck"
    Then @alice's atServer answers "data:success"
    And @chuck is quarantined in "photos"

  Scenario: Removing notifications does not free a place
    Given @chuck is quarantined in "invitations.chat", with 10 notifications accepted in the last 24 hours
    And @alice's client has removed all 10
    When @chuck's atServer sends "notify:id:14:@alice:inv14.invitations.chat@chuck"
    Then @alice's atServer answers with the quarantine-limit error

  @replay
  Scenario: A repeated notification id does not count
    Given @chuck is quarantined in "invitations.chat", with 9 exchanges counted, the last being notification 9
    When @chuck's atServer sends notification 9 again
    Then @alice's atServer answers "data:success"
    And @chuck has 9 exchanges counted in "invitations.chat"
    And @alice's atServer holds notification 9 once

  Scenario: A notification already expired on arrival does not count
    Given @chuck is quarantined in "invitations.chat", with 9 exchanges counted
    When @chuck's atServer sends a notification in "invitations.chat" whose expiry has passed
    Then @alice's atServer answers "data:success"
    And @chuck has 9 exchanges counted in "invitations.chat"

  Scenario: A refused notification does not count
    Given @chuck is quarantined in "invitations.chat", with 9 exchanges counted
    When @chuck's atServer sends a notify command of 15,361 bytes in "invitations.chat"
    Then @alice's atServer answers with the quarantine-size error
    And @chuck has 9 exchanges counted in "invitations.chat"

  Scenario: A notification at the size cap is accepted
    Given @chuck is quarantined in "invitations.chat"
    When @chuck's atServer sends a notify command of 15,360 bytes in "invitations.chat"
    Then @alice's atServer answers "data:success"

  Scenario: A notification over the size cap is refused
    Given @chuck is quarantined in "invitations.chat"
    When @chuck's atServer sends a notify command of 15,361 bytes in "invitations.chat"
    Then @alice's atServer answers with the quarantine-size error
    And @alice's atServer holds no notification of it

  Scenario: Metadata counts toward the size cap
    Given @chuck is quarantined in "invitations.chat"
    When @chuck's atServer sends a notify command in "invitations.chat" with an empty value and 16,000 bytes of appMetadata
    Then @alice's atServer answers with the quarantine-size error

  Scenario: A quarantined notification with ttr creates no cached key
    Given @chuck is quarantined in "invitations.chat"
    When @chuck's atServer sends "notify:id:15:update:ttr:60000:@alice:inv15.invitations.chat@chuck:<value>"
    Then @alice's atServer answers "data:success"
    And @alice's atServer holds notification 15
    And @alice's atServer holds no "cached:@alice:inv15.invitations.chat@chuck"

  Scenario: A quarantined delete removes no cached key
    Given @chuck is quarantined in "invitations.chat"
    And @alice's atServer holds "cached:@alice:old.invitations.chat@chuck", cached with ccd
    When @chuck's atServer sends "notify:id:16:delete:ttr:60000:ccd:true:@alice:old.invitations.chat@chuck"
    Then @alice's atServer answers "data:success"
    And @alice's atServer still holds "cached:@alice:old.invitations.chat@chuck"

  Scenario: An ephemeral notification counts
    Given @chuck is quarantined in "invitations.chat", with 9 exchanges counted
    When @chuck's atServer sends "notify:id:17:eph:@alice:inv17.invitations.chat@chuck"
    Then @alice's atServer answers "data:success"
    And @chuck has 10 exchanges counted in "invitations.chat"

  Scenario: A namespace's holders set its count limit
    Given @alice's chat client has sent "gate:rule:invitations.chat:open:limit:3"
    And @chuck is quarantined in "invitations.chat", with 3 exchanges counted in the last 24 hours
    When @chuck's atServer sends "notify:id:18:@alice:inv18.invitations.chat@chuck"
    Then @alice's atServer answers with the quarantine-limit error

  Scenario: A namespace's holders set its size cap
    Given @alice's chat client has sent "gate:rule:invitations.chat:open:size:1024"
    And @chuck is quarantined in "invitations.chat"
    When @chuck's atServer sends a notify command of 1,025 bytes in "invitations.chat"
    Then @alice's atServer answers with the quarantine-size error

  Scenario Outline: A setting above the operator's ceiling is refused
    Given the operator's ceiling for "<setting>" on @alice's atServer is <ceiling>
    When @alice's chat client sends "gate:rule:invitations.chat:open:<setting>:<value>"
    Then @alice's atServer answers with the illegal-argument error, AT0022
    And the rule for "invitations.chat" is unchanged

    Examples:
      | setting             | ceiling  | value    |
      | limit               | 100      | 101      |
      | size                | 65536    | 65537    |
      | maxQuarantined      | 1000     | 1001     |
      | maxQuarantinedBytes | 16777216 | 16777217 |

  Scenario: Admitting an atSign ends its counting
    Given @chuck is quarantined in "invitations.chat", with 10 exchanges counted in the last 24 hours
    And @alice's chat client has sent "gate:admit:invitations.chat:@chuck"
    When @chuck's atServer sends "notify:id:19:@alice:inv19.invitations.chat@chuck"
    Then @alice's atServer answers "data:success"

  Scenario: Denying a quarantined atSign refuses it from then on
    Given @chuck is quarantined in "invitations.chat"
    And @alice's chat client has sent "gate:deny:invitations.chat:@chuck"
    When @chuck's atServer sends "notify:id:20:@alice:inv20.invitations.chat@chuck"
    Then @alice's atServer answers with the not-accepted error

  Scenario: A stream from an atSign not admitted is refused
    Given @chuck is quarantined in "invitations.chat"
    When @chuck's atServer opens a stream to @alice in "invitations.chat"
    Then @alice's atServer answers with the not-accepted error

  Scenario: A scan answers only entries in namespaces where the atSign is admitted
    Given @bob is admitted in "chat" and quarantined in "invitations.chat"
    And @alice's atServer holds "@bob:status.chat@alice" and "@bob:profile.invitations.chat@alice"
    When @bob's atServer sends "scan"
    Then @alice's atServer answers ["status.chat@alice"]
    And @bob's count in "invitations.chat" is unchanged

  Scenario: A scan from an atSign admitted nowhere answers an empty list
    Given @dave is admitted nowhere on @alice's atServer
    And @alice's atServer holds "@dave:profile.invitations.chat@alice"
    When @dave's atServer sends "scan"
    Then @alice's atServer answers []

  Scenario: notify:list answers only notifications in namespaces where the atSign is admitted
    Given @bob is admitted in "chat" and quarantined in "invitations.chat"
    And @alice's atServer has sent @bob a notification in "chat" and one in "invitations.chat"
    When @bob's atServer sends "notify:list"
    Then @alice's atServer answers with the notification in "chat" only

  Scenario: A client that asks receives quarantined notifications, marked
    Given @chuck is quarantined in "invitations.chat"
    And @alice's client is monitoring, and asks for quarantined notifications
    When @alice's atServer accepts "notify:id:21:@alice:inv21.invitations.chat@chuck"
    Then @alice's client receives notification 21 with "quarantined": true

  Scenario: A client that does not ask is never sent a quarantined notification
    Given @chuck is quarantined in "invitations.chat"
    And @alice's client is monitoring, without asking for quarantined notifications
    When @alice's atServer accepts "notify:id:22:@alice:inv22.invitations.chat@chuck"
    Then @alice's client does not receive notification 22

  Scenario: notify:list from a client that does not ask leaves quarantined notifications out
    Given @alice's atServer holds notification 22 from quarantined @chuck in "invitations.chat"
    When @alice's client sends "notify:list" without asking for quarantined notifications
    Then @alice's atServer's answer does not include notification 22

  Scenario: notify:fetch from a client that does not ask answers as for no such notification
    Given @alice's atServer holds notification 22 from quarantined @chuck in "invitations.chat"
    When @alice's client sends "notify:fetch:22" without asking for quarantined notifications
    Then @alice's atServer answers {"id":"22","notificationStatus":"NotificationStatus.expired"}

  Scenario: Admitting the sender does not rewrite the mark
    Given @alice's atServer holds notification 21 from @chuck, accepted while @chuck was quarantined
    And @alice's chat client has sent "gate:admit:invitations.chat:@chuck"
    When @alice's client fetches notification 21, asking for quarantined notifications
    Then notification 21 carries "quarantined": true

  @dos
  Scenario: A full quarantine refuses atSigns seen for the first time
    Given "invitations.chat" holds as many quarantined atSigns as its bound allows
    And @erin is in none of its sets
    When @erin's atServer sends "notify:id:23:@alice:inv23.invitations.chat@erin"
    Then @alice's atServer answers with the quarantine-limit error
    And @erin is still in none of the sets of "invitations.chat"

  @dos
  Scenario: Quarantined notifications held up to the byte bound refuse the next one
    Given the quarantined notifications held in "invitations.chat" have reached its byte bound
    And @chuck is quarantined in it, under the count limit
    When @chuck's atServer sends "notify:id:24:@alice:inv24.invitations.chat@chuck"
    Then @alice's atServer answers with the quarantine-limit error

  @dos
  Scenario: A quarantined atSign that goes quiet for a window drops back to none
    Given @chuck is quarantined in "invitations.chat"
    And nothing from @chuck has counted there in the last 24 hours
    When @alice's atServer next checks the quarantined set of "invitations.chat"
    Then @chuck is in none of its sets

  @dos
  Scenario: A full quarantine in one namespace leaves another alone
    Given "invitations.chat" holds as many quarantined atSigns as its bound allows
    And namespace "photos" on @alice's atServer is open, and @erin is in none of its sets
    When @erin's atServer sends "notify:id:25:@alice:pic.photos@erin"
    Then @alice's atServer answers "data:success"

  @dos
  Scenario: A namespace's holders set its bound on quarantined atSigns
    Given @alice's chat client has sent "gate:rule:invitations.chat:open:maxQuarantined:2"
    And @chuck and @dave are quarantined in "invitations.chat"
    When @erin's atServer sends "notify:id:26:@alice:inv26.invitations.chat@erin"
    Then @alice's atServer answers with the quarantine-limit error

  @dos
  Scenario: A restart does not reset a count
    Given @chuck is quarantined in "invitations.chat", with 10 exchanges counted in the last 24 hours
    And @alice's atServer has restarted since
    When @chuck's atServer sends "notify:id:27:@alice:inv27.invitations.chat@chuck"
    Then @alice's atServer answers with the quarantine-limit error

  @race
  Scenario: Two exchanges at the limit at once accept exactly one
    Given @chuck is quarantined in "invitations.chat", with 9 exchanges counted in the last 24 hours
    When @chuck's atServer sends notifications 28 and 29 on two connections at the same moment
    Then @alice's atServer answers "data:success" to one and the quarantine-limit error to the other

  @race
  Scenario: Two atSigns seen for the first time, competing for the last place, admit exactly one to quarantine
    Given "invitations.chat" holds one fewer quarantined atSign than its bound allows
    And @erin and @frank are in none of its sets
    When @erin's and @frank's atServers each send a notification in "invitations.chat" at the same moment
    Then @alice's atServer answers "data:success" to one and the quarantine-limit error to the other
