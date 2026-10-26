Feature: An atServer with telemetry on reports what becomes of notifications

  The sending atServer reports notification.delivered when the
  recipient's atServer answers data:success, notification.expired when the
  notification expires before delivery, and notification.error when the
  recipient atSign is not in the atDirectory. The receiving atServer
  reports notification.received when another atServer delivers a
  notification that it stores, once the live pushes to the monitor
  connections open at that moment have been written or 10 seconds have
  passed. pushed_to lists the enrollment ids of the devices it was written
  to, one entry per enrollment, and push_count counts them. A connection
  authenticated by CRAM is neither listed nor counted. A legacy pkam
  connection is listed as primary. Each event carries the notification id
  (atsign.notification.ids). The atServer sends no connection events.

  data:success also answers five kinds of drop on the receiving atServer
  (text notifications, keys that are not well formed, reserved
  namespaces, notifications already expired, ids it already holds), so
  notification.delivered means "accepted or dropped by the recipient's
  atServer". A collector matches notification.delivered to
  notification.received on sender, recipient and id together, never on
  the id alone: the sender chooses the id.

  Races: the report closes over its own notification and the pushes made
  for it. The receiving atServer holds notifications by id alone: once it
  holds one with an id, a later one with that id that another atServer
  delivers, whichever atSign sent it, is answered data:success and
  dropped with a warning, so it is neither pushed nor in a
  notification.received. The enrollment reported for a push is the one
  it was authorized for, read in the same step as the authorization. The
  report waits and is sent from the zone the notification manager was
  created in, never inside the notify that delivered the notification,
  and a failure while sending it is logged at severe, so it can change
  neither the peer's answer nor its connection.
  Replay: a peer re-sending an id it has already delivered is dropped
  before it is stored (unchanged), so it is not reported twice.
  DoS: every attribute is bounded: ids at 36 characters for notifications
  accepted since that bound (one stored earlier keeps its id), atSigns at 55,
  enrollment ids are UUIDs or primary that this atServer generated, and
  pushed_to has at most one entry per enrollment holding a live monitor
  connection, itself at most inbound_max_limit.
  Forgery: atsign.notification.from is the atSign that passed pol;
  pushed_to holds only enrollment ids this atServer assigned at pkam;
  nothing in it comes from a peer or from a client's own claims.
  Impersonation: a CRAM connection that ran enroll:request carries the
  new enrollment's id but is not that device; it is not listed.

  Scenario: A received notification lists each device it was written to once
    Given monitor connections as enrollment e1, as enrollment e1 again, as enrollment e2, and by CRAM
    When @bob's atServer delivers a notification all four may read
    Then notification.received has push_count 2
    And pushed_to is [{"atsign.enrollment.id": e1}, {"atsign.enrollment.id": e2}]

  Scenario: A legacy pkam connection is listed as primary
    Given a monitor connection authenticated by legacy pkam
    When @bob's atServer delivers a notification
    Then pushed_to is [{"atsign.enrollment.id": "primary"}]

  Scenario: A CRAM connection that ran enroll:request is not listed
    Given a CRAM connection that ran enroll:request, approved on the spot as enrollment e3, then monitor
    When @bob's atServer delivers a notification
    Then notification.received has push_count 0 and no pushed_to

  Scenario: A device that may not read the notification is not listed
    Given monitor connections as enrollment e1, which holds wavi, and e2, which holds only buzz
    When @bob's atServer delivers a notification for phone.wavi
    Then pushed_to lists e1 only

  Scenario: A push is reported under the enrollment it was written for
    Given a connection that ran monitor as enrollment e1 and then authenticated with pkam as enrollment e2
    When @bob's atServer delivers a notification e2 may read
    Then pushed_to lists e2, not e1

  Scenario: A push still waiting after 10 seconds is not counted
    Given a monitor connection as enrollment e1 whose push has not been written 10 seconds after the notification arrived
    When the report goes out
    Then notification.received has push_count 0
    And the notify verb was answered data:success without waiting for the push

  Scenario: A later notification with an id already held is dropped, whoever sent it
    Given @bob's atServer has delivered notification n9, pushed to one monitor
    When @carol's atServer delivers a notification with id n9
    Then it is answered data:success and dropped with a warning
    And the monitor is pushed only @bob's, and one notification.received is sent, from @bob

  Scenario: A repeated delivery of the same id is reported once
    Given @bob's atServer has delivered notification n2
    When it delivers n2 again
    Then one notification.received is sent

  Scenario: A report still waiting at shutdown is sent before telemetry stops
    Given a notification.received report waiting on a push
    When the atServer stops
    Then the report is sent before lifecycle.stopped, counting the pushes written by then

  Scenario Outline: The sending atServer reports the outcome of each notification it sends
    Given @alice's atServer is sending notification n1 to @bob
    When <outcome>
    Then it sends <event> with atsign.notification.to "@bob" and atsign.notification.ids ["n1"]

    Examples:
      | outcome                              | event                                  |
      | @bob's atServer answers data:success | atsign.atserver.notification.delivered |
      | n1 expires before it is delivered    | atsign.atserver.notification.expired   |
      | @bob is not in the atDirectory       | atsign.atserver.notification.error     |

  Scenario Outline: The atServer sends no connection events
    Given an atServer with telemetry on
    When <action>
    Then no event whose name starts atsign.atserver.connection. is sent

    Examples:
      | action                                         |
      | a client authenticates with cram               |
      | a client authenticates with pkam               |
      | a CRAM connection's enroll:request is approved |
      | an authenticated connection runs monitor       |
      | an authenticated connection closes             |

  Scenario: Nothing is sent while telemetry is off
    Given an atServer with telemetry off
    When a notification is delivered, received and pushed
    Then no event is sent
