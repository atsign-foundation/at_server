Feature: Notifications may not use this atSign's reserved namespaces

  A notification uses a reserved namespace when its key, without any public:
  or cached: prefix, has a last dot-separated segment that begins with "__",
  or a dot-separated segment that, folded, is __e or begins with one of
  __manage, __atserver, __global, __private, __otp and __config. When
  another atServer, proved by pol, delivers such a notification, it is
  dropped: nothing is stored, this atServer logs a warning, and the sending
  atServer is answered data:success, so it neither retries nor holds back
  later notifications to this atSign. This holds for update and delete
  notifications. An atSign's own client, whether authenticated by cram or
  pkam, may not send a notification into a reserved namespace, to another
  atSign or to itself, and an atServer queues none for another atSign,
  whatever asked for it. A key with a segment that only begins with "__",
  such as <kid>.__ck.wavi, is unaffected.

  A key notification's key must also be a well-formed atKey, as at_commons
  defines one when a client builds a key: after any public: or cached:
  prefix, only letters, digits, emoji and _ - . ' * ". One that is not is
  refused with AT0003 when an atSign's own client sends it, and dropped in
  the same way when another atServer delivers it. That check comes first, so
  such a key is refused or dropped as not well-formed, whatever namespace it
  uses.

  Races: the check reads only the request and the connection's own state.
  Replay: nothing is stored or consumed for a dropped notification.
  DoS: the drop compares the key's segments and writes one warning line;
  answering success means a sending atServer neither retries nor holds back
  later notifications.
  Forgery and impersonation: a notification from another atSign never uses
  a namespace that this atServer and this atSign's own clients write.

  Scenario Outline: Another atServer's notification into a reserved namespace is dropped
    Given a peer that has proved itself as @bob by pol
    When it sends a <kind> notification of <key> to @alice
    Then it gets data:success
    And nothing is stored
    And @alice's atServer logs a warning naming <namespace> and @bob
    And the connection stays open

    Examples:
      | kind   | key                                         | namespace  |
      | update | @alice:x.__manage@bob                       | __manage   |
      | delete | @alice:x.__manage@bob                       | __manage   |
      | update | @alice:x.a.__e@bob                          | __e        |
      | update | @alice:x.__atserver@bob                     | __atserver |
      | update | @alice:x.__MANAGE@bob                       | __MANAGE   |
      | update | @alice:x.__anything@bob                     | __anything |
      | update | @alice:x.__manage.wavi@bob                  | __manage   |
      | update | @alice:x.__E.wavi@bob                       | __E        |
      | update | @alice:public:__manage.wavi@bob             | __manage   |
      | update | @alice:x.new.enrollments.__managex.wavi@bob | __managex  |
      | update | @alice:x.__manage-x.wavi@bob                | __manage-x |

  Scenario Outline: Another atServer still notifies into an app namespace through a reserved-looking segment
    Given a peer that has proved itself as @bob by pol
    When it sends an update notification of @alice:<key>@bob to @alice
    Then it gets data:success

    Examples:
      | key                           |
      | ck1.__ck.wavi                 |
      | x.__en.apkamSymmetricKey.wavi |

  Scenario Outline: An atSign's own client may not send a notification into a reserved namespace
    Given @alice's client authenticated by <auth>
    When it asks @alice's atServer to send an update notification of <key> to <recipient>
    Then it is refused with AT0009: Notification to <recipient> may not use reserved namespace __manage
    And nothing is sent or stored

    Examples:
      | auth | key                     | recipient |
      | cram | @bob:x.__manage@alice   | @bob      |
      | pkam | @bob:x.__manage@alice   | @bob      |
      | cram | @alice:x.__manage@alice | @alice    |
      | pkam | @alice:x.__manage@alice | @alice    |

  Scenario Outline: An atSign's own client may not send a notification whose key is not a well-formed atKey
    Given @alice's client authenticated by cram
    When it asks @alice's atServer to send an update notification of <key> to @bob
    Then it is refused with AT0003
    And nothing is sent or stored

    Examples:
      | key                          |
      | @bob:x.__manage:y.wavi@alice |
      | @bob:x.__manage y.wavi@alice |
      | @bob:x#y.wavi@alice          |

  Scenario Outline: Another atServer's notification whose key is not a well-formed atKey is dropped
    Given a peer that has proved itself as @bob by pol
    When it sends an update notification of <key> to @alice
    Then it gets data:success
    And nothing is stored
    And @alice's atServer logs a warning naming @bob
    And the connection stays open

    Examples:
      | key                                       |
      | @alice:x.__manage:y.wavi@bob              |
      | @alice:x.__manage y.wavi@bob              |
      | @alice:stream_id.wavi @bob:s1:Zi50eHQ=:12 |

  Scenario: An atServer queues no notification to another atSign into a reserved namespace, whatever asked for it
    Given @alice's atServer holds a queued notification for @bob of @bob:x.__manage@alice
    When @alice's atServer starts
    Then it is not sent to @bob
    And it is marked errored
