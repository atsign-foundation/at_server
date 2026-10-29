Feature: keys: answers only an enrollment's own two encryption keys

  enroll:approve stores two keys for the enrollment it approves, each
  encrypted with that enrollment's APKAM symmetric key:
  <E>.default_enc_private_key.__manage@<atSign> and
  <E>.default_self_enc_key.__manage@<atSign>. On a connection
  authenticated as E, keys:get:keyName: with either name answers the stored
  value. Key names are compared folded.

  Every other keys: request is refused with AT0009 before the handler reads
  or writes the store: keys:put and keys:delete in every form, the
  keys:get:private, keys:get:self and keys:get:public listings, a keys:get
  naming any other key, another enrollment's included, and a keys:get that
  carries anything beside keyName, such as a visibility or a namespace. A
  connection carrying no enrollment id is refused with
  "Keys verb cannot be accessed without an enrollmentId". A legacy pkam:
  connection authenticates as the enrollment primary, which enroll:approve
  never approved, so it has neither key and its keys:get finds nothing.

  Races: keys: writes nothing. A keys:get that arrives while
  enroll:approve is storing the keys finds each key or is told it does not
  exist, and a repeated keys:get finds it once it is stored.
  Replay: no challenge or nonce is involved, and a repeated keys:get
  answers the same value.
  DoS: a refused request is answered without reading or writing the store;
  an answered one reads the enrollment record and one key.
  Forgery: keys: writes nothing, and answers only the two keys
  enroll:approve stored for the enrollment the connection is authenticated
  as.
  Impersonation: the two names are built from the enrollment the connection
  authenticated as, never from the request, and a keys:get naming another
  enrollment's key is refused before anything is read.

  Scenario Outline: An enrollment reads its own encryption key by keyName
    Given enrollment E was approved, and enroll:approve stored its <key>
    And a connection is authenticated as E
    When it sends keys:get:keyName:<E>.<name>.__manage@alice
    Then it gets the value enroll:approve stored

    Examples:
      | key                       | name                    |
      | encryption private key    | default_enc_private_key |
      | self encryption key       | default_self_enc_key    |

  @forgery @impersonation
  Scenario Outline: Every other keys: request is refused before the store is read or written
    Given enrollment E was approved, and enroll:approve stored its two keys
    And a connection is authenticated as E
    When it sends <request>
    Then it is refused with AT0009
    And nothing is stored, deleted or listed

    Examples:
      | request                                                                                                                   |
      | keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_<E> <value>                                         |
      | keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_<E>:keyName:myAESkey <value> |
      | keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:myAESkey:keyName:myPrivateKey <value> |
      | keys:put:public:namespace:app:keyName:__nskey <value>                                                                     |
      | keys:delete:keyName:<E>.default_enc_private_key.__manage@alice                                                            |
      | keys:get:private                                                                                                          |
      | keys:get:self                                                                                                             |
      | keys:get:public                                                                                                           |
      | keys:get:keyName:<F>.default_enc_private_key.__manage@alice, enrollment F's                                               |
      | keys:get:keyName:privatekey:at_secret                                                                                     |
      | keys:get:self:keyName:<E>.default_self_enc_key.__manage@alice                                                             |
      | keys:get:namespace:__global:keyName:<E>.default_self_enc_key.__manage@alice                                               |
      | keys:get:keyName:<E>.default_enc_private_key.__manage@alice <value>                                                       |

  Scenario: A connection carrying no enrollment id is refused
    Given a CRAM connection that has not sent enroll:request
    When it sends keys:get:keyName:<E>.default_self_enc_key.__manage@alice
    Then it is refused with "Keys verb cannot be accessed without an enrollmentId"
    And nothing is stored, deleted or listed

  Scenario: A legacy pkam: connection finds no encryption key
    Given a legacy pkam: connection, which authenticates as the enrollment primary
    When it sends keys:get:keyName:primary.default_enc_private_key.__manage@alice
    Then it is told the key does not exist

  @dos
  Scenario: A refused request from an enrollment that is not approved is refused for its form
    Given enrollment E is pending
    When the keys: handler is given keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_<E> <value> for E
    Then it is refused with AT0009, before E's record is read
