## 2026-11-15 — Replay initial KCP handshake during Auto QTYPE probing

- Cache up to four unique outbound KCP PUSH datagrams for the active conversation
  while HTTP Custom Auto is negotiating.
- On each QTYPE rotation, replay the cached datagrams through the single network
  send loop using the new candidate carrier, rather than sending only an empty poll.
- Preserve packet bytes exactly, discard stale candidate replays, and clear the
  handshake cache when a matching server KCP PUSH locks the selected QTYPE.
- Add regression tests for replay across multiple rotations, byte-for-byte packet
  preservation, duplicate suppression, and stopping replay after Auto lock.

## 2026-11-15 — Fix HTTP Custom MTU regression test for OpenWrt builds

- Correct the test fixture to use the DNS name-label byte-slice type expected by
  `dns.Name`.
- Run Go tests and vet with `CGO_ENABLED=0` in the OpenWrt instructions so the test
  binary does not require the host's unavailable `libresolv` development library.

## 2026-11-15 — Align name-carrier regression test with optional suffix

- Replace the obsolete rejection test for nonmatching RDATA tails. When the
  configured zone suffix is absent, labels that resemble another DNS name
  remain Base32 carrier data; the answer RR owner is still checked against the
  configured tunnel zone before the decoder is called.

## 2026-11-15 — Fix HTTP Custom name-carrier decoding and polling

- Accept NS/CNAME/MX/SRV name-carrier RDATA whose Base32 labels omit the tunnel
  zone suffix, while stripping the suffix when it is present.
- Wake the send loop immediately whenever Auto QTYPE rotates, ensuring each
  candidate gets a query even when exponential polling has backed off.
- Use a 125 ms initial poll interval and a 1-second maximum poll backoff for
  all HTTP Custom modes; keep standard DNSTT at 500 ms initial and 10 seconds
  maximum.
- Clamp negative computed HTTP Custom MTUs to zero and add regression tests for
  suffix-less carriers, Auto poll wakeups, polling bounds, and MTU underflow.

## 2026-11-15 — Expose HTTP Custom KCP profile in Passwall-SSH LuCI

- Add UCI option `KCP_PROFILE`, defaulting to `native` for existing routers.
- Add a LuCI selector for Native and Conservative KCP profiles.
- Validate the value in the apply script and supervisor, and pass it to
  `dnstt-client -kcp-profile` for UDP HTTP Custom mode.
- Extend the OpenWrt integration workflow to validate profile forwarding and
  LuCI form presence.

## 2026-11-15 — Enable congestion control in the conservative profile

- Change the opt-in conservative HTTP Custom KCP profile to `nc=0`, enabling
  KCP congestion control in addition to the 100 ms interval, normal minimum
  RTO, disabled fast-resend, and delayed ACKs. The native default remains
  `nc=1` to match the captured Android profile.
- Extract Noise NK negotiation into a deadline-aware helper and add a
  net.Pipe regression test proving the handshake returns a timeout when the
  responder never sends its message.

## 2026-11-15 — Bound Noise handshake and add high-RTT diagnostics

- Add a 60-second default deadline to Noise NK negotiation, with
  `-noise-timeout 0` to disable it. Log local listener readiness, handshake
  start, completion, and failures distinctly.
- Add an opt-in `-kcp-profile conservative` using nodelay=0, 100 ms interval,
  fastresend=0, and delayed ACKs. Keep the PCAP-matched `native` profile as
  the default; this profile switch is for controlled RTT/jitter comparison.
- Select the UDP socket family explicitly (udp4/udp6) based on the resolved
  destination address.
- Validate name-carrier RDataOffset is at least the 12-byte DNS header and
  remains inside the received DNS wire message before following compression
  pointers.
- Extend shadowsocks-style plugin forwarding to include `kcp-profile` and
  `noise-timeout`, with regression tests for these options, KCP profiles,
  address-family selection, and invalid RDataOffset values.

## 2026-11-15 — Harden HTTP Custom packet queues and DNS decoding

- Limit detailed KCP TX datagram/segment dumps to the first 30 successful sends;
  periodic DNS TX summaries remain available.
- Add per-session packet queue sizing. HTTP Custom queues now track the effective
  KCP window (minimum 128, maximum 4096), while standard DNSTT retains its
  upstream default of 128.
- Count and log incoming/outgoing packet-queue drops instead of leaving local
  queue pressure invisible.
- Correct literal newline escapes in HTTP Custom CLI validation errors.
- Reject apex answer owners and name-carrier RDATA whose target does not end in
  the configured tunnel zone; normalize DNS name-carrier octets byte-by-byte.
- Expand compressed-name tests to parse a real DNS wire message with multiple
  answers and verify the parser-populated RDataOffset.
- Pass HTTP Custom, QTYPE, and KCP-window options through SS_PLUGIN_OPTIONS.
- Add regression tests for queue capacities, overflow counters, apex filtering,
  wrong-zone rejection, raw DNS octets, and plugin argument forwarding.

## 2026-11-15 — HTTP Custom automatic QTYPE selection

- Add `-qtype auto` for UDP HTTP Custom mode. The client probes NS, TXT, CNAME,
  SRV, MX, then NULL, changing candidate every two seconds while negotiating.
- Decode delayed DNS responses using the RR type echoed in the DNS question.
- Lock the selected RR type only after a structurally valid KCP PUSH matching
  the active KCP conversation ID is received; stop the probe ticker after lock.
- Add AUTO to both UCI validation scripts and the LuCI QTYPE selector.
- Add unit tests for QTYPE parsing/order, response-carrier selection, KCP
  conversation matching, single-lock behavior, and conservative Auto MTU.
- Provider/resolver end-to-end behavior remains to be verified in CI and on
  the physical OpenWrt client. Fixed NS remains the known-good configuration.

# Changelog

## 2026-11-13 — Full native-framing Go client test passes on OpenWrt 25.12.5 VM

- Corrected OpenWrt run [43413615294](https://github.com/avidemx/dnstt-crypto/actions/runs/43413615294) completed successfully; artifact [14031515415](https://github.com/avidemx/dnstt-crypto/actions/runs/43413615294/artifacts/14031515415).
- The fixed guest script passed host-side `sh -n`; its stdout is live-streamed to the QEMU serial console and persisted by `tee` to `test.log`.
- Raw UDP DNS endpoint `8.8.8.8:53`, QTYPE NS, ClientID/E3/E8 native framing, independent DNS ID, KCP window 512 and effective MTU 128 worked on OpenWrt 25.12.5 x86/64.
- Received KCP ACK and PUSH segments for conversation `0c946e5c`; SSH banner passed with `SSH-2.0-dropbear_2019.78`.
- SSH password authentication passed; SSH dynamic SOCKS5 forwarding came up on `127.0.0.1:1080`; internet egress check succeeded (observed IP `150.109.13.91`).
- Download through the tunnel returned HTTP 200 and exactly 1,048,576 bytes in 20.929939 seconds (about 50,102 bytes/s). Guest test status was `0`.
- Go tests and static Linux x86_64 build passed in run [43413615293](https://github.com/avidemx/dnstt-crypto/actions/runs/43413615293). Binary SHA-256: `d1698f88a4b37de11c913e32e05f9a47d2e7e5d1c6d1e3f64878429b89bfd4d9`.
- Previous VM failure [43409565660](https://github.com/avidemx/dnstt-crypto/actions/runs/43409565660) was a missing `fi` syntax error, not protocol failure. Commit `7e13bcc` fixed the syntax, added pre-boot syntax validation, and enabled live console/log output.
- Next: physical OpenWrt 25 x86_64 loopback smoke test with the exact VM-passed binary. After hardware confirmation, evaluate two parallel sessions to match native HTTP Custom's two-session capture.


## 2026-11-13 — Fix OpenWrt guest test launcher and enable live console output

- Inspect the completed OpenWrt VM run [43409565660](https://github.com/avidemx/dnstt-crypto/actions/runs/43409565660). The guest booted, networking and APK package installation succeeded, and DNS prechecks ran, but the test script stopped before starting the Go client.
- Actual BusyBox shell parser error: `/root/run-httpcustom-dnstt-test.sh: line 244: syntax error: unexpected end of file (expecting "fi")`. The SSH-banner selection `if [ "$SELECTED" -eq 1 ]` block was missing its outer closing `fi`. The QEMU expect timeout was caused by the absent final status marker, not by a tunnel connection timeout.
- Add the missing `fi` and a host-side `sh -n "$ROOT/root/run-httpcustom-dnstt-test.sh"` validation before the OpenWrt image is unmounted.
- Remove the guest script's `exec >"$LOGDIR/test.log" 2>&1` redirect. The init service now invokes the guest script through `tee -a /root/httpcustom-dnstt-logs/test.log /dev/console`, so each echo/command output is visible live in the QEMU serial console and persisted to the log artifact.
- Correct the VM test banner to state QTYPE NS and native ClientID/E3/E8 framing.
- Corrected rerun [43413330070](https://github.com/avidemx/dnstt-crypto/actions/runs/43413330070) was queued at this checkpoint. It must pass the shell syntax check and then show the actual client TX/RX/KCP logs before any protocol conclusion is made.


## 2026-11-13 — Match native HTTP Custom QNAME framing from uploaded PCAP

- Analyze the user-uploaded capture `analysis/httpcustom/httpcustom-native.pcap` (SHA-256 `17b51aa1d448df6292e97c99fe27b2263ec54e3c9f404891122e81bb9f7a05f3`): 18,078 DNS packets over 41.13 seconds, all QTYPE NS to `8.8.8.8:53`.
- The capture contains two parallel UDP sessions. Each session prepends one stable 8-byte ClientID to every Base32 QNAME; the two observed session IDs differ, and each maps to its own KCP conversation ID.
- Confirm the native query frames: data is `ClientID[8] | E3 | random padding[3] | length[1] | KCP packet`; an empty poll is `ClientID[8] | E8 | random padding[8]`. Padding is fresh per query.
- DNS transaction IDs are independent of the ClientID and QNAME padding. The previous shared 10-byte DNS-ID assumption and the prior E8-data/E3-poll order were incorrect for the captured native session.
- Decode bidirectional KCP traffic from the NS answers: client PUSH/ACK segments and server PUSH/ACK segments carry the matching per-session KCP conversation IDs. This proves live two-way KCP exchange in the native app; it does not by itself reveal decrypted SSH authentication or SOCKS payload contents.
- Update the Go HTTP Custom encoder to transmit the stable `turbotunnel.ClientID`, use E3 for data and E8 for polls, and generate an independent DNS transaction ID. Reduce the computed client uplink MTU to account for the 13-byte native data-frame overhead.
- Add golden regression tests using the actual first captured native data query and poll bytes. Keep all changes isolated to the feature branch; the standard DNSTT framing path remains unchanged.
- The next validation is Go tests/vet/static build followed by the OpenWrt 25.12.5 VM test using the captured native QTYPE NS mode. Only advance to the physical router after the VM end-to-end test succeeds.


## 2026-11-13 — DNS ID A/B result: no KCP ACK in either mode

- OpenWrt 25.12.5 x86/64 VM A/B run [43400537305](https://github.com/avidemx/dnstt-crypto/actions/runs/43400537305) completed with failure at the SSH-banner stage and uploaded artifact [14025431528](https://github.com/avidemx/dnstt-crypto/actions/runs/43400537305/artifacts/14025431528).
- Same resolver (`8.8.8.8:53)), account, KCP profile and RR modes (CNAME/SRV) were used for native shared-buffer DNS ID and the diagnostic independent DNS ID.
- Native CNAME: 32 DNS queries; 14 NOERROR responses with one-byte RDATA `00`, 10 NXDOMAIN and 7 SERVFAIL. Native SRV: 31 queries; 13 NOERROR responses with seven zero RDATA bytes, 10 NXDOMAIN and 8 SERVFAIL.
- Independent CNAME: 31 queries; 13 NOERROR responses with one-byte RDATA `00`, 11 NXDOMAIN and 7 SERVFAIL. Independent SRV: 30 queries; 11 NOERROR responses with seven zero RDATA bytes, 10 NXDOMAIN and 9 SERVFAIL.
- No decoded payload bytes, inbound KCP segments or KCP ACKs were received in any of the four attempts. No SSH banner was reached.
- The instrumentation confirmed 32/32 native CNAME and 31/31 native SRV TX records used a DNS ID equal to `rand_head` (the first two bytes of the per-query 10-byte random buffer). The independent mode used a separate ID on all 31 CNAME and 30 SRV TX records.
- Earlier matrix [43345089444](https://github.com/avidemx/dnstt-crypto/actions/runs/43345089444) did receive a KCP ACK in independent-ID CNAME and SRV attempts. The A/B run did not reproduce those ACKs even in independent mode. Therefore, the current evidence does **not** isolate the earlier ACK difference to the DNS ID source; the DNS/server/account path appears to have changed or become intermittent between runs. This remains a hypothesis, not a confirmed server diagnosis.
- The Go test/vet/static-build workflow passed with the A/B code in [run 43400537105](https://github.com/avidemx/dnstt-crypto/actions/runs/43400537105).
- Next: preserve the per-query logs and compare DNS response behavior with the provider's active zone/listener/account state while the account is valid. Do not change the protocol default or KCP/Noise parameters based on this A/B result alone.

## 2026-11-13 — Controlled DNS ID A/B test added

- After the native shared-buffer DNS-ID retest stopped receiving KCP ACKs, add an explicit diagnostic-only switch `-httpcustom-independent-dns-id`. The protocol default remains native: DNS ID bytes come from the first two bytes of the same 10-byte random buffer used for E8/E3 prefix framing.
- Add `id_source` and `rand_head` TX diagnostics so the query ID source can be compared directly in the packet log.
- Extend the OpenWrt VM workflow to compare native and independent DNS-ID modes with the same Fikystore account, resolver (`8.8.8.8:53`) and QTYPEs (CNAME, SRV).
- Add a regression test asserting the bytes emitted in the DNS wire header exactly match the first two native random-buffer bytes.
- Go tests/vet/static build passed in run [43398153266](https://github.com/avidemx/dnstt-crypto/actions/runs/43398153266). The native-ID OpenWrt run [43398153194](https://github.com/avidemx/dnstt-crypto/actions/runs/43398153194) received zero KCP segments for both QTYPEs. The new A/B run has not yet completed.
- This diagnostic override is temporary and must not change the native-default behavior or standard DNSTT mode.

## 2026-11-13 — Native DNS transaction ID layout correction

- Disassembly of the HTTP Custom 8.0.22 Patch 2 native ARM64 library proved that `dnsQuery` generates one 10-byte random buffer per DNS query.
- The same buffer is passed into the query encoder: bytes 0–1 are used as the DNS transaction ID (serialized in network byte order); bytes 2–9 are used after the E8 data marker or bytes 2–4 after the E3 poll marker.
- Replace the Go client's independent DNS ID generation with the first two bytes of the existing 10-byte buffer.
- Replace the former random-only DNS ID test with deterministic byte-order and invalid-buffer-length tests.
- The corrected native-ID VM retest [43398153194](https://github.com/avidemx/dnstt-crypto/actions/runs/43398153194) ran 8.8.8.8:53 with CNAME and SRV but received no inbound KCP segment in either mode. DNS answers were received, but every answer decoded to zero payload bytes. This does not yet establish whether the cause is DNS-ID behavior or a change in the remote service/account path.

## 2026-11-13 — CNAME and SRV KCP ACK observed

- VM matrix run [43345089444](https://github.com/avidemx/dnstt-crypto/actions/runs/43345089444) tested four UDP endpoints by six RR modes.
- 8.8.8.8:53 with QTYPE CNAME returned a 26-byte length-prefixed KCP ACK. It matched the client's conversation ID, had command 0x52, sequence 1 and una=2.
- 8.8.8.8:53 with QTYPE SRV returned the same ACK structure for its own conversation ID.
- The remaining 22 combinations returned no decoded KCP segment. No server KCP PUSH/Noise response, SSH banner, SSH authentication, SOCKS5 session or 1 MiB transfer was observed.
- This positive ACK came from the previous Go build that used an independently generated DNS ID. The new native-compatible DNS ID change is now being retested; do not treat the earlier ACK as proof of full interoperability.

## Unreleased — HTTP Custom client compatibility

- Imported the upstream Go DNSTT client-side DNS, Noise, KCP, and transport
  queue packages from `1andrevich/dnstt` branch `plugin`.
- Added selectable `-httpcustom` mode for UDP DNS without changing the
  default standard DNSTT framing.
- Added HTTP Custom data (`0xE8`) and poll (`0xE3`) frames, random-prefix
  handling, Base32 QNAME encoding, and the custom NULL Base64 alphabet.
- Native APK disassembly later established the full per-query random-buffer
  layout: create one fresh 10-byte buffer per DNS query; bytes 0–1 supply the
  DNS transaction ID, bytes 2–9 form the E8 data prefix, and bytes 2–4 form
  the E3 poll prefix. The earlier independent-DNS-ID implementation was not
  native-compatible and is corrected in the 2026-11-13 update below.
- Added initial NS/MX/SRV/CNAME/NULL/TXT response decoding support and DNS
  RDATA wire-offset retention for compressed name records.
- Added bounded TX/RX DNS diagnostics and OpenWrt 25.12.5 x86_64 VM
  integration workflow.
- Added a separate HTTP Custom KCP window setting: default 512 for the
  HTTP Custom profile, while standard DNSTT retains the upstream 64 window.
- Matched the additional native HTTP Custom KCP tuning recovered from
  `slowdns.configureClientKCP`: `SetNoDelay(1, 20, 2, 1)`, ACK no-delay
  enabled, and write delay disabled. Standard DNSTT remains unchanged.
- Expanded VM coverage to UDP recursive resolvers 8.8.8.8/1.1.1.1 and direct
  Fikystore host ports 53/5300; every resolver/QTYPE attempt has a unique log.
- Offline tests and static Linux x86_64 build pass.
- The previous live VM attempts used the superseded account (`dnsv.sshvpn.web.id`)
  and are not valid tests of the current account. The current account uses
  `slowdns.fikystore.my.id`, `cloud.fikystore.my.id:22`, username `Free`, and
  repository secrets for the active password/public key. The VM now probes
  direct UDP SlowDNS ports 53 and 5300 across TXT, NULL, CNAME, NS, MX and SRV
  modes. Live tunnel and exact 1 MiB download are still pending.
- Artifact re-analysis corrected the earlier endpoint attribution: the
  verified 24-byte KCP ACK (command 0x52, sequence 1, conversation 0x9f392797)
  was returned by recursive resolver `8.8.8.8:53` with QTYPE TXT. It was not
  produced by direct `cloud.fikystore.my.id:53` / QTYPE NS. The VM workflow
  now reproduces the proven resolver + TXT combination.
- Auto QTYPE negotiation, calibration, bonding, and complete dedicated
  CNAME fragmentation remain pending.
