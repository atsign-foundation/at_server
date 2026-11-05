Feature: A connection that has authenticated with pkam may not cram

  Once a pkam has succeeded on a connection, a cram on that connection is
  refused and the connection closed. A pkam after a cram, and a cram after
  a cram, are unaffected. A batch carrying cram or pkam is refused whole
  (features/batch/batch_verbs.feature).

  Races: the refusal reads only the connection's own authentication state,
  which nothing but that connection's own commands writes.
  Replay: each cram answers a single-use challenge, so a captured digest
  answers nothing.
  DoS: the refusal reads one field and closes the connection.
  Forgery and impersonation: a connection stays bound to the authentication
  it made; nothing inside a batch can re-authenticate it, and a cram cannot
  replace a pkam on it.

  Scenario: A cram after a successful pkam on the same connection is refused and closes it
    Given a connection to @alice's atServer that has authenticated with pkam
    When it sends from:@alice and then cram:<digest>
    Then the atServer answers error:AT0009:cram may not follow a successful pkam on this connection, then the prompt @alice@
    And the connection is closed

  Scenario: A pkam after a cram on the same connection still succeeds
    Given a connection to @alice's atServer that has authenticated with cram
    When it sends from:@alice and then a valid pkam
    Then the pkam succeeds
