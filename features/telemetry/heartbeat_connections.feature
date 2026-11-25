Feature: An atServer with telemetry on reports in each heartbeat which enrollments are connected

  Every lifecycle.heartbeat carries connected_enrollment_count, the number
  of enrollments that, when the heartbeat is built, have at least one open
  connection authenticated by pkam as the atServer's own atSign. An APKAM
  connection counts toward its enrollment and a legacy pkam connection
  toward primary. A connection authenticated by CRAM, by another atSign
  (pol), or not at all is not counted, and neither is one that is closed or
  invalid. When the count is above 0 the heartbeat also carries
  connected_enrollments, one entry per enrollment sorted by id, each
  holding the enrollment id (atsign.enrollment.id) and how many of its
  connections are open (atsign.connection.count). The list holds at most
  100 entries, the first 100 by id; the count is always the full total, so
  a reader can tell the list was cut. A heartbeat without
  connected_enrollment_count comes from an atServer that predates this
  feature, so a reader takes it as unknown, not as no enrollment connected.
  lifecycle.started and lifecycle.stopped carry neither.

  Revoking an enrollment closes its open connections, so the next
  heartbeat no longer lists it. Reinstating it opens nothing; it is listed
  again once a device authenticates as it again.

  Races: the heartbeat reads the connections in the same step that builds
  it, from a copy of the pool, so a connection that opens or closes while it
  is built is counted by this heartbeat or the next, never half. If reading
  the connections fails, the heartbeat is still sent, without either
  attribute, and the failure is logged as a warning; it never reaches the
  server. No heartbeat is built once telemetry has shut down, and stopping
  the atServer closes its connections before lifecycle.stopped, so a
  heartbeat in between counts 0.
  DoS: the list is bounded at 100 entries and the pool itself at
  inbound_max_limit connections; enrollment ids are UUIDs or primary that
  this atServer generated.
  Forgery: only connections this atServer authenticated with pkam are
  counted; an id a client carries on a connection it has not proved with
  pkam, such as a CRAM connection that ran enroll:request, is not listed.

  Scenario: A heartbeat with no device connected counts 0 and lists none
    Given no connection is open
    When the heartbeat is sent
    Then connected_enrollment_count is 0
    And there is no connected_enrollments

  Scenario: An enrollment with two open connections is listed once, counting both
    Given two connections authenticated by APKAM as enrollment e1
    When the heartbeat is sent
    Then connected_enrollment_count is 1
    And connected_enrollments is [{"atsign.enrollment.id": e1, "atsign.connection.count": 2}]

  Scenario: A legacy pkam connection is listed as primary
    Given a connection authenticated by legacy pkam
    When the heartbeat is sent
    Then connected_enrollments is [{"atsign.enrollment.id": "primary", "atsign.connection.count": 1}]

  Scenario: A CRAM connection is neither listed nor counted
    Given a connection authenticated by CRAM, and a CRAM connection that ran enroll:request, approved on the spot as enrollment e3
    When the heartbeat is sent
    Then connected_enrollment_count is 0
    And there is no connected_enrollments

  Scenario: Connections from other atSigns and unauthenticated connections are not counted
    Given a connection authenticated by pol as @bob, a connection that ran from:@alice and no pkam, and a connection that authenticated by APKAM as e1 and then failed a later pkam
    And a connection authenticated by APKAM as enrollment e2
    When the heartbeat is sent
    Then connected_enrollments lists e2 only, with connection count 1

  Scenario: Closed and invalid connections are not counted
    Given connections authenticated by APKAM as enrollment e1, one open and one closed
    And a connection authenticated by APKAM as enrollment e2 that is invalid
    When the heartbeat is sent
    Then connected_enrollment_count is 1
    And connected_enrollments is [{"atsign.enrollment.id": e1, "atsign.connection.count": 1}]

  Scenario: More than 100 connected enrollments are cut to the first 100 by id
    Given 150 enrollments, each with one connection authenticated by APKAM
    When the heartbeat is sent
    Then connected_enrollment_count is 150
    And connected_enrollments lists the first 100 enrollment ids in order

  Scenario: Revoking an enrollment drops it from the next heartbeat
    Given approved enrollments e1, with two connections authenticated by APKAM, and e2, with one
    And the heartbeat lists e1 and e2
    When enrollment e1 is revoked
    Then the next heartbeat lists e2 only, and connected_enrollment_count is 1

  Scenario: A reinstated enrollment is listed again once its device reconnects
    Given enrollment e1 was revoked, closing its connections
    When e1 is unrevoked
    Then the next heartbeat does not list e1
    When a device authenticates by APKAM as e1 again
    Then the next heartbeat lists e1 with connection count 1

  Scenario: A failure reading the connections still sends the heartbeat
    Given reading the connections throws
    When the heartbeat is sent
    Then it carries neither connected_enrollment_count nor connected_enrollments
    And a warning is logged, and nothing reaches the server's zone

  Scenario: No heartbeat follows lifecycle.stopped
    Given an atServer with telemetry on, sending a heartbeat every millisecond
    When telemetry shuts down
    Then no heartbeat is sent after lifecycle.stopped
    And the connections are not read after it

  Scenario: lifecycle.started and lifecycle.stopped carry no connection attributes
    Given a connection authenticated by APKAM as enrollment e1
    When telemetry starts and then shuts down
    Then neither lifecycle.started nor lifecycle.stopped carries connected_enrollment_count
