Feature: Text notifications are retired

  messageType:text notifications are no longer accepted. A client's notify
  or notify:all with messageType:text is refused with AT0003 and nothing is
  stored. A text notification that another atServer, proved by pol,
  delivers is dropped: nothing is stored, this atServer logs a warning, and
  the sending atServer is answered data:success, so it neither retries nor
  holds back later notifications. info and info:brief list notify.text as
  Retired. Text notifications already stored still list and fetch.

  Races: the check reads only the request.
  Replay: nothing is stored for a refused or dropped text notification.
  DoS: the check compares the messageType; a dropped one writes one warning
  line.
  Forgery and impersonation: unchanged; a dropped notification is logged
  against the atSign its sender proved by pol.

  Scenario Outline: A client's text notification is refused
    Given @alice's authenticated client
    When it sends <command>
    Then it is refused with AT0003: messageType:text is no longer supported
    And nothing is stored

    Examples:
      | command                                       |
      | notify:messageType:text:@bob:hello            |
      | notify:all:messageType:text:@bob,@carol:hello |

  Scenario Outline: Another atServer's text notification is dropped
    Given a peer that has proved itself as @bob by pol
    When it sends a text notification for <recipient>
    Then it gets data:success
    And nothing is stored
    And @alice's atServer logs a warning naming @bob

    Examples:
      | recipient |
      | @alice    |
      | @carol    |

  Scenario Outline: info lists notify.text as Retired
    When @alice's authenticated client sends <verb>
    Then its features list notify.text with status Retired

    Examples:
      | verb       |
      | info       |
      | info:brief |

  Scenario: Text notifications already stored still list and fetch
    Given @alice's atServer holds a text notification n stored before text was retired
    When @alice's client sends notify:list and then notify:fetch for n's id
    Then both return n
