Feature: An atServer's exchanges with a slow, faulty or flaky atServer

  @bob's atServer reaches @alice's atServer through a fault proxy that sits
  between the two atServers and passes TLS through untouched. Each scenario is
  run against the trunk image and the image under test, alternately, and the
  image under test must reach trunk's outcome and never fail later than trunk.
  The tests are tests/at_functional_test/adverse, run by runAdverse.sh.

  Races: the hang-up and freeze scenarios race a close or a silence against a
  waiting read, across real sockets.
  Replay: the notification scenarios require each notification to arrive
  exactly once, with no duplicate after a retry.
  DoS: a stalled or frozen peer holds a lookup only for the inter-chunk budget.
  Forgery: none arises; the proxy changes when bytes arrive and whether the
  connection stays open, never what the bytes are.
  Impersonation: none arises; the proxy never touches TLS, so the peer is the
  same atServer.

  Background:
    Given @bob's atServer reaches @alice's atServer through a fault proxy
    And @alice's atServer holds "@bob:lookup0.gatebench@alice" with the value "value"

  Scenario: A lookup through added latency answers the value
    Given the proxy delays each chunk 100 ms, with 50 ms of jitter
    When @bob's client sends "lookup:bypassCache:true:lookup0.gatebench@alice"
    Then it is answered "data:value"

  Scenario: A reply delivered one byte at a time is answered whole
    Given the proxy passes @alice's replies one byte every 20 ms
    When @bob's client sends "lookup:bypassCache:true:lookup0.gatebench@alice"
    Then it is answered "data:value"

  Scenario: A reply that stops arriving fails as the inter-chunk budget passes, and the next lookup succeeds
    Given the proxy stops passing @alice's replies
    When @bob's client sends "lookup:bypassCache:true:lookup0.gatebench@alice"
    Then it is answered with an error between 10 and 13 seconds later
    And once the proxy passes replies again, the next lookup is answered "data:value"

  Scenario: The remote atServer hanging up mid-reply fails the lookup at once, and the next lookup succeeds
    Given the proxy closes the connection halfway through @alice's next reply
    When @bob's client sends "lookup:bypassCache:true:lookup0.gatebench@alice"
    Then it is answered with an error within 1 second
    And the next lookup is answered "data:value"

  Scenario: A remote atServer that freezes fails the lookup as the inter-chunk budget passes, and is reached again once it resumes
    Given @alice's atServer is frozen
    When @bob's client sends "lookup:bypassCache:true:lookup0.gatebench@alice"
    Then it is answered with an error between 10 and 13 seconds later
    And once @alice's atServer resumes, the next lookup is answered "data:value"

  Scenario: A remote atServer that restarts is reached again
    Given @alice's atServer has restarted since @bob's atServer last reached it
    When @bob's client sends "lookup:bypassCache:true:lookup0.gatebench@alice" until it is answered "data:value"
    Then it is answered "data:value" within 30 seconds

  Scenario: Notifications through added latency each arrive once
    Given the proxy delays each chunk 100 ms, with 50 ms of jitter
    When @bob's client sends 50 notifications to @alice
    Then @alice's monitor receives each of them exactly once

  Scenario: Notifications sent while the remote atServer is frozen each arrive once after it resumes
    Given @alice's atServer is frozen
    When @bob's client sends 20 notifications to @alice
    And @alice's atServer resumes
    Then @alice's monitor receives each of them exactly once, within the atServer's retry interval
