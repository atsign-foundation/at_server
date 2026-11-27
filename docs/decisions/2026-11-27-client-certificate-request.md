# Request a client certificate per connection, decided from the ALPN offer

- Status: Proposed
- Date: 2026-11-27
- Issue: atsign-foundation/at_server#2953
- Acceptance scenarios: `features/connections/client_certificate_request.feature`

## Context

The atServer has one TLS listener. `bindAndListen` binds it with `requestClientCertificate: true` (`packages/at_secondary_server/lib/src/server/at_secondary_impl.dart:769-773`), so every client is sent a CertificateRequest during the handshake. The listener offers two ALPN protocols, `atProtocol/1.0` and `http/1.1`. `acceptSocket` (`at_secondary_impl.dart:692`) reads the negotiated protocol only after the handshake: `atProtocol/1.0` or none goes to the verb path, anything else goes to the HTTP handler, which serves `/ws`.

Peer atServers rely on the request. A `from:` for another atSign is checked against the peer's certificate (`verb/handler/from_verb_handler.dart:216`). Peers offer no ALPN.

A browser opening `wss://host:port/ws` is also sent the request. The browser has no certificate to present for `/ws` and can show a certificate picker. The server never reads a certificate on the HTTP and `/ws` path.

dart:io fixes `requestClientCertificate` per bind and offers no ClientHello or ALPN-select callback. So the request cannot be varied by ALPN on one `SecureServerSocket`.

## Decision

Decide per connection, from the ClientHello, whether to request a certificate.

1. Bind a plain `ServerSocket` on the same port.
2. Read the first TLS record, reassembling it across TCP reads, then pause the socket.
3. Parse the ALPN extension. Skip the CertificateRequest only when the offer contains `http/1.1` and does not contain `atProtocol/1.0`.
4. Call `SecureSocket.secureServer(socket, context, bufferedData: <bytes read>, requestClientCertificate: <decision>)`, with the same `SecurityContext` and ALPN list as today.
5. Every other case requests a certificate, as today: no ALPN, `atProtocol/1.0` offered, a parse failure, a first record over 16 KiB, a ClientHello that spans more than one record, a non-handshake first byte, or no complete record within 5 seconds.
6. Invariant: a connection that was not asked for a certificate and negotiated anything other than `http/1.1` is closed before any verb runs.
7. A non-self `from:` over `/ws` is refused, since that connection has no TLS peer certificate.
8. A pre-handshake limiter allows at most 64 sockets in the peek phase. A socket over the limit skips the peek and is handshaken with the request. It is never closed for the limit.

A new at_server-local wrapper around `ServerSocket` replaces `PseudoServerSocket`'s `SecureServerSocket` argument, so the change needs no at_utils release.

## Consequences

- Browsers that offer only `http/1.1` are not sent a CertificateRequest, so `/ws` opens with no picker.
- Peer atServers, native clients and every connection that reaches the verb path are asked for a certificate exactly as today. `from:` verification is unchanged.
- The accept loop gains a ClientHello parser. Every failure of it falls back to requesting a certificate.
- The change adds a pre-handshake limiter, a peek timeout and a byte cap.
- A certificate reload still applies, because each handshake reads the current default context.
- A TLS 1.3 HelloRetryRequest needs no handling. The decision is fixed on the connection before the handshake starts, and a forced HelloRetryRequest was observed to behave the same.
- No new port, no root directory change and no client change.
- Other TLS clients that offer only `http/1.1` also go unasked. They reach only the HTTP and `/ws` path.

## Alternatives considered

| Alternative | Verdict | Reason |
|---|---|---|
| Per-connection decision from the ALPN offer | Chosen | Same port, no discovery, infrastructure or client change. Every path that can reach the verb handler is still asked. |
| A second certificate-free listener on another port | Fallback | No hand-written parser. It needs a way for browsers to discover the port, a port allocation and firewall change across the swarm, and a client change. Use it if a ClientHello parser is unwanted. |
| No request anywhere | Rejected | Peer `from:` loses the certificate gate in front of it. |
| TLS 1.3 post-handshake authentication | Rejected | Not available in dart:io, and browsers do not offer it. |
