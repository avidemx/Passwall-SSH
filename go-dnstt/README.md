# HTTP Custom-compatible DNSTT client (OpenWrt)

This directory contains a **client-only** build of the Go DNSTT client from
[1andrevich/dnstt](https://github.com/1andrevich/dnstt), plus an isolated
experimental HTTP Custom SlowDNS DNS-carrier mode.

No DNSTT server is built or modified here. The standard DNSTT client mode
remains available and is selected by default. The HTTP Custom mode is enabled
only with `-httpcustom`.

## Status

- Upstream DNS, Noise, KCP client, and transport-queue source imported from
  branch `plugin`, commit
  `17aa1fed864cd5493e3d09a14df1b8b5cc1df123`.
- HTTP Custom query framing follows the uploaded native PCAP:
  - Data frame: `ClientID[8] | 0xE3 | 3 random bytes | one-byte payload length | payload`.
  - Empty poll: `ClientID[8] | 0xE8 | 8 random bytes`.
  - ClientID is stable for each DNSPacketConn/session; padding is random per
    query; DNS transaction IDs are generated independently.
- NS QTYPE uplink uses lower-case, unpadded Base32 QNAME labels.
- The custom no-padding Base64 alphabet for NULL uploads is implemented.
- Initial downlink decoders exist for NS, MX, SRV, CNAME, NULL, and TXT.
- The active Fikystore account test uses `slowdns.fikystore.my.id`; current
  credentials and server public key remain in GitHub Actions secrets only.
  The earlier VM test was blocked by a guest-script syntax error; it did not
  exercise the protocol.
- The native HTTP Custom packet capture used during development (not tracked
  in this repository) confirms QTYPE NS and two-way KCP traffic using the
  stable ClientID/E3/E8 framing above. The Go encoder and golden frame tests
  now match that evidence.
- Corrected VM run [43413615294](https://github.com/avidemx/dnstt-crypto/actions/runs/43413615294)
  passed the full flow: KCP ACK/PUSH, SSH banner, password authentication,
  SOCKS5 internet egress, and an exact 1,048,576-byte download (HTTP 200).
  Run [43413615293](https://github.com/avidemx/dnstt-crypto/actions/runs/43413615293)
  passed Go tests and static Linux x86_64 build. The VM-tested binary SHA-256 is
  `d1698f88a4b37de11c913e32e05f9a47d2e7e5d1c6d1e3f64878429b89bfd4d9`.
  The earlier launcher syntax issue is fixed; QEMU console output is live and
  also saved to `test.log`.
- The HTTP Custom KCP profile now matches the native tuning recovered from
  `slowdns.configureClientKCP`: `SetNoDelay(1, 20, 2, 1)`, ACK no-delay enabled,
  write delay disabled, and window 512. Standard DNSTT keeps its upstream
  KCP settings.
- HTTP Custom Auto selection, calibration, session bonding, and the dedicated
  CNAME fragmentation/sender behavior are not implemented. Do not use
  `-qtype cname` as a production mode until that path is completed and tested.

This is a work-in-progress compatibility implementation, not a claim of full
HTTP Custom interoperability.

## Build and offline tests

On a Go 1.24.x build host:

```sh
cd go-dnstt
go test ./...
go vet ./dns ./dnstt-client ./turbotunnel
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dnstt-client-linux-amd64 ./dnstt-client
```

The CI workflow runs these tests and produces a static Linux x86_64 binary.

## OpenWrt 25.x usage

Copy the static binary and the server public key to the router. Use the native-capture resolver/QTYPE pair 8.8.8.8:53 and NS as the UDP
transport endpoint; the tunnel suffix remains slowdns.fikystore.my.id. The
native PCAP confirms NS name-carrier downlink and stable per-session ClientID
framing. The HTTP Custom profile defaults to KCP window 512;

```sh
chmod 0755 /root/dnstt-client
/root/dnstt-client -httpcustom -qtype ns -kcp-window 512 -udp 8.8.8.8:53 \
  -pubkey-file /root/akun/server.pub \
  slowdns.fikystore.my.id 127.0.0.1:7000
```

The command creates a local TCP listener. Connect your SSH client or local
proxy to that listener as appropriate for the account. The SSH username and
password are account-specific and are not embedded in the binary.

Use the standard DNSTT mode (without `-httpcustom`) for a standard DNSTT
server. Do not mix the two DNS framing formats.

## Current live-test status

The OpenWrt 25.12.5 x86_64 VM has passed the complete one-session test:
1. UDP DNS via 8.8.8.8:53 / NS returned data and bidirectional KCP.
2. Noise/KCP completed and exposed the SSH banner.
3. SSH password authentication succeeded.
4. SOCKS5 forwarding reached the internet.
5. Exactly 1,048,576 bytes were downloaded through the tunnel and verified.

The next stage is a physical OpenWrt 25 x86_64 loopback test using the same
binary and arguments. Keep the listener bound to 127.0.0.1 during the first
hardware test. The two-session native-app configuration is a later optimization;
the current single-session Go implementation has passed the end-to-end VM test.

No server-side changes are required or planned for this client-only task.
