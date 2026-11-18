package main

import (
	"bytes"
	"encoding/base32"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"reflect"
	"testing"
	"time"

	"www.bamsoftware.com/git/dnstt.git/noise"

	"www.bamsoftware.com/git/dnstt.git/dns"
)

func TestSelectKCPWindow(t *testing.T) {
	tests := []struct {
		name       string
		requested  int
		httpCustom bool
		want       int
		wantErr    bool
	}{
		{name: "HTTP Custom profile default", httpCustom: true, want: 512},
		{name: "standard upstream default", want: 64},
		{name: "explicit window override", requested: 256, httpCustom: true, want: 256},
		{name: "reject zero only when explicit is not possible", requested: -1, httpCustom: true, wantErr: true},
		{name: "reject excessive window", requested: 4097, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := selectKCPWindow(tt.requested, tt.httpCustom)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected KCP window validation error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Fatalf("KCP window=%d want %d", got, tt.want)
			}
		})
	}
	if got := queueSizeForKCPWindow(64); got != 128 {
		t.Fatalf("queue capacity for KCP window 64=%d want 128", got)
	}
	if got := queueSizeForKCPWindow(512); got != 512 {
		t.Fatalf("queue capacity for KCP window 512=%d want 512", got)
	}
}

func TestParseHTTPcustomQType(t *testing.T) {
	tests := []struct {
		input string
		want uint16
		wantErr bool
	}{
		{"auto", 0, false}, {"AUTO", 0, false}, {"0", 0, false},
		{"ns", httpCustomQTypeNS, false}, {"TXT", httpCustomQTypeTXT, false},
		{"cname", httpCustomQTypeCNAME, false}, {"null", httpCustomQTypeNULL, false},
		{"mx", httpCustomQTypeMX, false}, {"srv", httpCustomQTypeSRV, false},
		{"https", 0, true},
	}
	for _, tt := range tests {
		got, err := parseHTTPcustomQType(tt.input)
		if tt.wantErr {
			if err == nil { t.Errorf("parseHTTPcustomQType(%q) expected error", tt.input) }
			continue
		}
		if err != nil { t.Errorf("parseHTTPcustomQType(%q): %v", tt.input, err); continue }
		if got != tt.want { t.Errorf("parseHTTPcustomQType(%q)=%d want %d", tt.input, got, tt.want) }
	}
}

func TestHTTPcustomAutoQTypeOrder(t *testing.T) {
	want := []uint16{httpCustomQTypeNS, httpCustomQTypeTXT, httpCustomQTypeCNAME, httpCustomQTypeSRV, httpCustomQTypeMX, httpCustomQTypeNULL}
	if len(httpCustomAutoQTypes) != len(want) { t.Fatalf("candidate count=%d want %d", len(httpCustomAutoQTypes), len(want)) }
	for i, qtype := range want {
		if httpCustomAutoQTypes[i] != qtype { t.Errorf("candidate[%d]=%s want %s", i, httpCustomQTypeName(httpCustomAutoQTypes[i]), httpCustomQTypeName(qtype)) }
		if got, expected := nextHTTPcustomQType(qtype), want[(i+1)%len(want)]; got != expected {
			t.Errorf("next after %s=%s want %s", httpCustomQTypeName(qtype), httpCustomQTypeName(got), httpCustomQTypeName(expected))
		}
	}
}

func TestHTTPcustomAutoQTypeRotationRequestsPoll(t *testing.T) {
	c := &DNSPacketConn{
		autoQType: true,
		pollChan:  make(chan struct{}, 1),
	}
	c.autoQTypeCurrent.Store(uint32(httpCustomQTypeNS))
	got, ok := c.advanceHTTPcustomAutoQType()
	if !ok {
		t.Fatal("Auto QTYPE rotation unexpectedly stopped")
	}
	if got != httpCustomQTypeTXT {
		t.Fatalf("rotated QTYPE=%s want TXT", httpCustomQTypeName(got))
	}
	select {
	case <-c.pollChan:
	default:
		t.Fatal("QTYPE rotation did not wake sendLoop")
	}

	c.autoQTypeMu.Lock()
	c.autoQTypeLocked = true
	c.autoQTypeMu.Unlock()
	got, ok = c.advanceHTTPcustomAutoQType()
	if ok {
		t.Fatal("QTYPE rotation continued after Auto lock")
	}
	if got != httpCustomQTypeTXT {
		t.Fatalf("locked QTYPE changed to %s", httpCustomQTypeName(got))
	}
	select {
	case <-c.pollChan:
		t.Fatal("locked QTYPE queued an unnecessary poll")
	default:
	}
}

func TestHTTPcustomAutoHandshakeReplayAcrossRotations(t *testing.T) {
	const conv = 0x12345678
	makePush := func(sn uint32, payload byte) []byte {
		packet := make([]byte, 25)
		binary.LittleEndian.PutUint32(packet[0:4], conv)
		packet[4] = 81
		binary.LittleEndian.PutUint32(packet[12:16], sn)
		binary.LittleEndian.PutUint32(packet[20:24], 1)
		packet[24] = payload
		return packet
	}

	first := makePush(0, 0xa1)
	second := makePush(1, 0xb2)
	third := makePush(2, 0xc3)
	fourth := makePush(3, 0xd4)
	fifth := makePush(4, 0xe5)
	originalPackets := [][]byte{
		append([]byte(nil), first...),
		append([]byte(nil), second...),
		append([]byte(nil), third...),
		append([]byte(nil), fourth...),
	}
	c := &DNSPacketConn{
		autoQType: true,
		pollChan: make(chan struct{}, 1),
		autoReplayChan: make(chan httpCustomReplayPacket, autoHandshakeReplayQueue),
	}
	c.autoQTypeCurrent.Store(uint32(httpCustomQTypeNS))
	c.autoQTypeConv.Store(conv)
	c.autoQTypeConvSet.Store(true)

	for _, packet := range [][]byte{first, second, third, fourth, fifth, first} {
		c.rememberHTTPcustomAutoHandshakePacket(packet)
	}
	if got := len(c.autoHandshakePackets); got != autoHandshakeReplayLimit {
		t.Fatalf("cached handshake packet count=%d want limit %d", got, autoHandshakeReplayLimit)
	}

	for _, wantQType := range []uint16{httpCustomQTypeTXT, httpCustomQTypeCNAME} {
		gotQType, ok := c.advanceHTTPcustomAutoQType()
		if !ok || gotQType != wantQType {
			t.Fatalf("rotation QTYPE=%s ok=%t want %s", httpCustomQTypeName(gotQType), ok, httpCustomQTypeName(wantQType))
		}
		for _, wantPacket := range [][]byte{first, second, third, fourth} {
			select {
			case replay := <-c.autoReplayChan:
				if replay.qtype != wantQType {
					t.Fatalf("replay QTYPE=%s want %s", httpCustomQTypeName(replay.qtype), httpCustomQTypeName(wantQType))
				}
				if !bytes.Equal(replay.packet, wantPacket) {
					t.Fatalf("replayed KCP packet changed: got %x want %x", replay.packet, wantPacket)
				}
			default:
				t.Fatalf("missing replay packet for QTYPE %s", httpCustomQTypeName(wantQType))
			}
		}
	}
	for i, packet := range [][]byte{first, second, third, fourth} {
		if !bytes.Equal(packet, originalPackets[i]) {
			t.Fatalf("replay modified original KCP packet %d", i)
		}
	}
}

func TestHTTPcustomAutoHandshakeReplayStopsAfterLock(t *testing.T) {
	const conv = 0x87654321
	packet := make([]byte, 25)
	binary.LittleEndian.PutUint32(packet[0:4], conv)
	packet[4] = 81
	binary.LittleEndian.PutUint32(packet[20:24], 1)
	packet[24] = 0x5a

	c := &DNSPacketConn{
		autoQType: true,
		pollChan: make(chan struct{}, 1),
		autoReplayChan: make(chan httpCustomReplayPacket, autoHandshakeReplayQueue),
		autoQTypeStop: make(chan struct{}),
	}
	c.autoQTypeCurrent.Store(uint32(httpCustomQTypeNS))
	c.autoQTypeConv.Store(conv)
	c.autoQTypeConvSet.Store(true)
	c.rememberHTTPcustomAutoHandshakePacket(packet)
	if len(c.autoHandshakePackets) != 1 {
		t.Fatal("initial handshake packet was not cached")
	}
	if !c.lockHTTPcustomAutoQType(httpCustomQTypeNS) {
		t.Fatal("expected Auto QTYPE to lock")
	}
	if len(c.autoHandshakePackets) != 0 {
		t.Fatal("handshake cache was not cleared after lock")
	}
	// A replay already queued before lock must be discarded without writing.
	if err := c.sendHTTPcustomAutoReplay(nil, httpCustomReplayPacket{
		packet: packet,
		qtype: httpCustomQTypeNS,
	}, nil); err != nil {
		t.Fatalf("discarding a queued replay after lock: %v", err)
	}
	if _, ok := c.advanceHTTPcustomAutoQType(); ok {
		t.Fatal("QTYPE rotation continued after lock")
	}
	select {
	case replay := <-c.autoReplayChan:
		t.Fatalf("unexpected replay after lock: QTYPE=%s", httpCustomQTypeName(replay.qtype))
	default:
	}
}

func TestHTTPcustomPollTiming(t *testing.T) {
	standard := &DNSPacketConn{}
	custom := &DNSPacketConn{httpCustom: true}
	auto := &DNSPacketConn{httpCustom: true, autoQType: true}

	if got := standard.initialPollDelay(); got != initPollDelay {
		t.Fatalf("standard initial poll delay=%s want %s", got, initPollDelay)
	}
	if got := custom.initialPollDelay(); got != httpCustomInitPollDelay {
		t.Fatalf("HTTP Custom initial poll delay=%s want %s", got, httpCustomInitPollDelay)
	}
	if got := auto.pollDelayCeiling(); got != httpCustomMaxPollDelay {
		t.Fatalf("unlocked Auto poll ceiling=%s want %s", got, httpCustomMaxPollDelay)
	}
	auto.autoQTypeMu.Lock()
	auto.autoQTypeLocked = true
	auto.autoQTypeMu.Unlock()
	if got := auto.pollDelayCeiling(); got != httpCustomMaxPollDelay {
		t.Fatalf("locked Auto poll ceiling=%s want %s", got, httpCustomMaxPollDelay)
	}
	if got := custom.pollDelayCeiling(); got != httpCustomMaxPollDelay {
		t.Fatalf("fixed-QTYPE HTTP Custom poll ceiling=%s want %s", got, httpCustomMaxPollDelay)
	}
}

func TestHTTPcustomResponseQType(t *testing.T) {
	resp := &dns.Message{Question: []dns.Question{{Type: httpCustomQTypeCNAME}}, Answer: []dns.RR{{Type: httpCustomQTypeTXT}}}
	if got := httpCustomResponseQType(resp, httpCustomQTypeNS); got != httpCustomQTypeCNAME { t.Fatalf("question QTYPE=%s want CNAME", httpCustomQTypeName(got)) }
	resp = &dns.Message{Answer: []dns.RR{{Type: httpCustomQTypeSRV}}}
	if got := httpCustomResponseQType(resp, httpCustomQTypeNS); got != httpCustomQTypeSRV { t.Fatalf("answer fallback=%s want SRV", httpCustomQTypeName(got)) }
	resp = &dns.Message{}
	if got := httpCustomResponseQType(resp, httpCustomQTypeMX); got != httpCustomQTypeMX { t.Fatalf("fallback=%s want MX", httpCustomQTypeName(got)) }
}

func TestHTTPcustomHasKCPPush(t *testing.T) {
	const conv = 0x12345678
	push := make([]byte, 28)
	binary.LittleEndian.PutUint32(push[0:4], conv)
	push[4] = 81
	binary.LittleEndian.PutUint32(push[20:24], 4)
	if !httpCustomHasKCPPush(push, conv) { t.Fatal("matching KCP PUSH was not detected") }
	if httpCustomHasKCPPush(push, conv+1) { t.Fatal("PUSH from another conversation was accepted") }
	ack := make([]byte, 24)
	binary.LittleEndian.PutUint32(ack[0:4], conv)
	ack[4] = 82
	if httpCustomHasKCPPush(ack, conv) { t.Fatal("ACK must not confirm Auto") }
	invalid := make([]byte, 24)
	binary.LittleEndian.PutUint32(invalid[0:4], conv)
	invalid[4] = 81
	binary.LittleEndian.PutUint32(invalid[20:24], 1)
	if httpCustomHasKCPPush(invalid, conv) { t.Fatal("truncated PUSH was accepted") }
}

func TestHTTPcustomAutoLocksOnce(t *testing.T) {
	c := &DNSPacketConn{autoQType: true, autoQTypeStop: make(chan struct{})}
	c.autoQTypeCurrent.Store(uint32(httpCustomQTypeNS))
	if !c.lockHTTPcustomAutoQType(httpCustomQTypeTXT) { t.Fatal("first QTYPE should lock") }
	if got := c.currentHTTPcustomQType(); got != httpCustomQTypeTXT { t.Fatalf("locked QTYPE=%s want TXT", httpCustomQTypeName(got)) }
	if c.lockHTTPcustomAutoQType(httpCustomQTypeCNAME) { t.Fatal("QTYPE changed after Auto lock") }
	select { case <-c.autoQTypeStop: default: t.Fatal("probe loop was not stopped") }
}

func TestHTTPcustomFrameMatchesNativeCapture(t *testing.T) {
	clientID := []byte{0x6c, 0x3d, 0x3e, 0xf5, 0x27, 0x5c, 0x1f, 0x83}
	padding := []byte{0x3a, 0x07, 0x68}
	// First data query from the uploaded native capture: KCP PUSH, 26 bytes.
	packet := []byte{
		0xc6, 0xf6, 0xcf, 0xcc, 0x51, 0x00, 0x00, 0x02,
		0x0e, 0xc1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
		0x30,
	}

	frame, err := encodeHTTPcustomFrame(clientID, packet, padding)
	if err != nil {
		t.Fatal(err)
	}
	want := append([]byte{}, clientID...)
	want = append(want, 0xe3, 0x3a, 0x07, 0x68, byte(len(packet)))
	want = append(want, packet...)
	if !bytes.Equal(frame, want) {
		t.Fatalf("native data frame mismatch: got %x want %x", frame, want)
	}

	pollPadding := []byte{0x02, 0xc9, 0x29, 0xc3, 0x6a, 0x6a, 0xbf, 0x95}
	poll, err := encodeHTTPcustomFrame(clientID, nil, pollPadding)
	if err != nil {
		t.Fatal(err)
	}
	wantPoll := append([]byte{}, clientID...)
	wantPoll = append(wantPoll, 0xe8)
	wantPoll = append(wantPoll, pollPadding...)
	if !bytes.Equal(poll, wantPoll) {
		t.Fatalf("native poll frame mismatch: got %x want %x", poll, wantPoll)
	}
}

func TestHTTPcustomFrameRejectsInvalidInputs(t *testing.T) {
	clientID := make([]byte, 8)
	if _, err := encodeHTTPcustomFrame(clientID[:7], []byte("abc"), make([]byte, numPadding)); err == nil {
		t.Fatal("expected a non-8-byte ClientID to be rejected")
	}
	if _, err := encodeHTTPcustomFrame(clientID, []byte("abc"), make([]byte, 2)); err == nil {
		t.Fatal("expected data frame with incorrect padding length to be rejected")
	}
	if _, err := encodeHTTPcustomFrame(clientID, nil, make([]byte, 7)); err == nil {
		t.Fatal("expected poll frame with incorrect padding length to be rejected")
	}
}

func TestHTTPcustomFrameBounds(t *testing.T) {
	clientID := make([]byte, 8)
	padding := make([]byte, numPadding)
	if _, err := encodeHTTPcustomFrame(clientID, make([]byte, 224), padding); err == nil {
		t.Fatal("expected 224-byte packet to be rejected")
	}
	if _, err := encodeHTTPcustomFrame(clientID, make([]byte, 223), padding); err != nil {
		t.Fatalf("223-byte packet should be accepted: %v", err)
	}
}

func TestGenerateHTTPcustomDNSID(t *testing.T) {
	if _, err := generateHTTPcustomDNSID(); err != nil {
		t.Fatal(err)
	}
}

func TestHTTPcustomTransportMTUUsesNativeClientIDAndPadding(t *testing.T) {
	domain, err := dns.ParseName("slowdns.fikystore.my.id")
	if err != nil {
		t.Fatal(err)
	}
	if got := httpCustomTransportMTU(domain, httpCustomQTypeNS); got != 128 {
		t.Fatalf("native NS uplink MTU=%d want 128", got)
	}
	if got := httpCustomTransportMTU(domain, 0); got != 128 {
		t.Fatalf("Auto conservative uplink MTU=%d want 128", got)
	}
}

func TestHTTPcustomTransportMTUClampsNegativeValue(t *testing.T) {
	largeZone := dns.Name{
		bytes.Repeat([]byte{'a'}, 59),
		bytes.Repeat([]byte{'b'}, 59),
		bytes.Repeat([]byte{'c'}, 59),
		bytes.Repeat([]byte{'d'}, 59),
	}
	if got := httpCustomTransportMTU(largeZone, httpCustomQTypeNS); got != 0 {
		t.Fatalf("negative MTU was not clamped: got %d want 0", got)
	}
}

func TestHTTPcustomCompactAlphabet(t *testing.T) {
	input := []byte{0xe8, 0x00, 0xff, 0x31, 0x32, 0x33}
	got := make([]byte, httpCustomCompactEncoding.EncodedLen(len(input)))
	httpCustomCompactEncoding.Encode(got, input)
	want := []byte("5ad+mtiZ")
	if !bytes.Equal(got, want) {
		t.Fatalf("custom Base64 mismatch: got %q want %q", got, want)
	}
	decoded := make([]byte, httpCustomCompactEncoding.DecodedLen(len(got)))
	n, err := httpCustomCompactEncoding.Decode(decoded, got)
	if err != nil || !bytes.Equal(decoded[:n], input) {
		t.Fatalf("custom Base64 round trip failed: %v %x", err, decoded[:n])
	}
}

func TestHTTPcustomQNAMERecordTypes(t *testing.T) {
	domain, err := dns.ParseName("dnsv.sshvpn.web.id")
	if err != nil {
		t.Fatal(err)
	}
	frame := []byte{0xe8, 1, 2, 3, 4, 5, 6, 7, 8, 2, 0xaa, 0xbb}
	for _, qtype := range []uint16{2, 5, 15, 16, 33} {
		name, err := encodeHTTPcustomQNAME(frame, qtype, domain)
		if err != nil {
			t.Fatalf("qtype %d: %v", qtype, err)
		}
		joined := bytes.Join(name[:len(name)-len(domain)], nil)
		decoded := make([]byte, httpCustomBase32Encoding.DecodedLen(len(joined)))
		n, err := httpCustomBase32Encoding.Decode(decoded, bytes.ToUpper(joined))
		if err != nil || !bytes.Equal(decoded[:n], frame) {
			t.Fatalf("qtype %d Base32 round trip failed: %v", qtype, err)
		}
	}
	nullName, err := encodeHTTPcustomQNAME(frame, httpCustomQTypeNULL, domain)
	if err != nil {
		t.Fatal(err)
	}
	nullJoined := bytes.Join(nullName[:len(nullName)-len(domain)], nil)
	nullDecoded := make([]byte, httpCustomCompactEncoding.DecodedLen(len(nullJoined)))
	n, err := httpCustomCompactEncoding.Decode(nullDecoded, nullJoined)
	if err != nil || !bytes.Equal(nullDecoded[:n], frame) {
		t.Fatalf("NULL compact round trip failed: %v", err)
	}
}

func TestHTTPcustomNSCompressedNameCarrier(t *testing.T) {
	// Parse a real DNS wire message with two Answer records. The NS RDATA
	// compression pointer targets the Question QNAME, and its offset is
	// computed by the parser rather than injected into the RR manually.
	zone, err := dns.ParseName("test.example")
	if err != nil {
		t.Fatal(err)
	}
	qname, err := dns.ParseName("mzxw6.test.example")
	if err != nil {
		t.Fatal(err)
	}
	qnameWire, err := dnsNameWireForTest(qname)
	if err != nil {
		t.Fatal(err)
	}
	wire := []byte{
		0x00, 0x01, 0x81, 0x80,
		0x00, 0x01, // QDCOUNT
		0x00, 0x02, // ANCOUNT
		0x00, 0x00, // NSCOUNT
		0x00, 0x00, // ARCOUNT
	}
	wire = append(wire, qnameWire...)
	wire = append(wire, 0x00, 0x02, 0x00, 0x01) // QTYPE=NS, QCLASS=IN

	// First answer: unrelated A record, to ensure the later RDATA offset
	// accounts for all preceding records.
	wire = append(wire, 0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 1, 2, 3, 4)

	// Second answer: NS RDATA is a compression pointer to the Question QNAME.
	rrStart := len(wire)
	wire = append(wire, 0xc0, 0x0c, 0x00, 0x02, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xc0, 0x0c)
	wantRDataOffset := rrStart + 12

	msg, err := dns.MessageFromWireFormat(wire)
	if err != nil {
		t.Fatalf("parse DNS wire message: %v", err)
	}
	if len(msg.Answer) != 2 {
		t.Fatalf("answer count=%d want 2", len(msg.Answer))
	}
	if got := msg.Answer[1].RDataOffset; got != wantRDataOffset {
		t.Fatalf("parsed RDataOffset=%d want %d", got, wantRDataOffset)
	}
	decoded := decodeHTTPcustomAnswer(wire, &msg, zone, httpCustomQTypeNS)
	want, _ := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString("MZXW6")
	if !bytes.Equal(decoded, want) {
		t.Fatalf("compressed name payload mismatch: %x want %x", decoded, want)
	}
}

func TestHTTPcustomRejectsApexAnswer(t *testing.T) {
	zone, err := dns.ParseName("test.example")
	if err != nil {
		t.Fatal(err)
	}
	resp := &dns.Message{
		Flags: 0x8180,
		Answer: []dns.RR{{
			Name: zone, Type: httpCustomQTypeNULL, Class: dns.ClassIN,
			Data: []byte{0x01, 0x02, 0x03},
		}},
	}
	if got := decodeHTTPcustomAnswer(nil, resp, zone, httpCustomQTypeNULL); len(got) != 0 {
		t.Fatalf("apex record produced payload %x; want no payload", got)
	}
}

func TestHTTPcustomNameCarrierWithoutZoneSuffix(t *testing.T) {
	zone, err := dns.ParseName("test.example")
	if err != nil {
		t.Fatal(err)
	}
	target, err := dns.ParseName("mzxw6")
	if err != nil {
		t.Fatal(err)
	}
	targetWire, err := dnsNameWireForTest(target)
	if err != nil {
		t.Fatal(err)
	}
	wire := append(make([]byte, 12), targetWire...)
	rr := dns.RR{Data: targetWire, RDataOffset: 12}
	got, err := decodeHTTPcustomNameCarrier(wire, rr, httpCustomQTypeNS, zone)
	if err != nil {
		t.Fatalf("suffix-less NS name carrier was rejected: %v", err)
	}
	want, _ := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString("MZXW6")
	if !bytes.Equal(got, want) {
		t.Fatalf("suffix-less name-carrier payload=%x want %x", got, want)
	}
}

func TestHTTPcustomNameCarrierNonmatchingTailRemainsPayload(t *testing.T) {
	zone, err := dns.ParseName("test.example")
	if err != nil {
		t.Fatal(err)
	}
	target, err := dns.ParseName("mzxw6.other.example")
	if err != nil {
		t.Fatal(err)
	}
	targetWire, err := dnsNameWireForTest(target)
	if err != nil {
		t.Fatal(err)
	}
	wire := append(make([]byte, 12), targetWire...)
	rr := dns.RR{Data: targetWire, RDataOffset: 12}

	// When the configured zone suffix is absent, all labels belong to the
	// carrier. A tail that resembles another DNS zone is still valid Base32
	// input and cannot be distinguished from payload by the DNS name alone.
	encoded := httpCustomBase32NameBytes([]string{"mzxw6", "other", "example"})
	want := make([]byte, httpCustomBase32Encoding.DecodedLen(len(encoded)))
	n, err := httpCustomBase32Encoding.Decode(want, encoded)
	if err != nil {
		t.Fatalf("decode expected carrier bytes: %v", err)
	}

	got, err := decodeHTTPcustomNameCarrier(wire, rr, httpCustomQTypeNS, zone)
	if err != nil {
		t.Fatalf("nonmatching tail was not treated as carrier payload: %v", err)
	}
	if !bytes.Equal(got, want[:n]) {
		t.Fatalf("carrier payload=%x want %x", got, want[:n])
	}
}

func TestHTTPcustomNameCarrierRejectsInvalidRDataOffset(t *testing.T) {
	zone, err := dns.ParseName("test.example")
	if err != nil {
		t.Fatal(err)
	}
	wire := make([]byte, 64)
	for _, offset := range []int{0, 11, len(wire), len(wire) + 1} {
		rr := dns.RR{Data: []byte{0xc0, 0x0c}, RDataOffset: offset}
		if _, err := decodeHTTPcustomNameCarrier(wire, rr, httpCustomQTypeNS, zone); err == nil {
			t.Errorf("RDataOffset=%d was accepted", offset)
		}
	}
}

func TestHTTPcustomNameBytesPreserveRawDNSOctets(t *testing.T) {
	label := string([]byte{0xff, 'a'})
	got := httpCustomBase32NameBytes([]string{label})
	want := []byte{0xff, 'A'}
	if !bytes.Equal(got, want) {
		t.Fatalf("byte normalization=%x want %x", got, want)
	}
}

func TestSSPluginHTTPcustomOptions(t *testing.T) {
	base := []string{"dnstt-client", "-udp", "8.8.8.8:53", "-pubkey", "test-key"}
	got := appendSSPluginFeatureFlags(base, "udp=8.8.8.8:53;httpcustom=true;qtype=auto;kcp-window=512;kcp-profile=conservative;noise-timeout=45s")
	want := []string{"dnstt-client", "-udp", "8.8.8.8:53", "-pubkey", "test-key",
		"-httpcustom", "-qtype", "auto", "-kcp-window", "512",
		"-kcp-profile", "conservative", "-noise-timeout", "45s"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("plugin args=%q want %q", got, want)
	}
}

func TestSelectHTTPcustomKCPProfile(t *testing.T) {
	tests := []struct {
		name       string
		want       httpCustomKCPProfile
		wantErr    bool
	}{
		{name: "native default", want: httpCustomKCPProfile{
			name: "native", nodelay: 1, interval: 20, fastresend: 2,
			nocwnd: 1, ackNoDelay: true, writeDelay: false,
		}},
		{name: "conservative", want: httpCustomKCPProfile{
			name: "conservative", nodelay: 0, interval: 100, fastresend: 0,
			nocwnd: 0, ackNoDelay: false, writeDelay: false,
		}},
		{name: "invalid", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			name := tt.name
			if name == "native default" { name = "" }
			if name == "invalid" { name = "turbo" }
			got, err := selectHTTPcustomKCPProfile(name)
			if tt.wantErr {
				if err == nil { t.Fatal("expected unsupported profile error") }
				return
			}
			if err != nil { t.Fatal(err) }
			if got != tt.want { t.Fatalf("profile=%+v want %+v", got, tt.want) }
		})
	}
}

func TestNoiseClientHandshakeTimesOut(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	serverRead := make(chan struct{})
	go func() {
		defer close(serverRead)
		var lengthBytes [2]byte
		if _, err := io.ReadFull(server, lengthBytes[:]); err != nil {
			return
		}
		message := make([]byte, int(binary.BigEndian.Uint16(lengthBytes[:])))
		_, _ = io.ReadFull(server, message)
		// Deliberately do not send the responder handshake message.
	}()

	privateKey, err := noise.GeneratePrivkey()
	if err != nil {
		t.Fatal(err)
	}
	publicKey := noise.PubkeyFromPrivkey(privateKey)
	started := time.Now()
	_, err = noiseClientWithTimeout(client, publicKey, 40*time.Millisecond)
	if err == nil {
		t.Fatal("Noise handshake unexpectedly succeeded without a server response")
	}
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("Noise handshake error=%v; want timeout", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("Noise handshake timeout took %s; want <1s", elapsed)
	}
	<-serverRead
}

func TestUDPListenNetworkSelectsAddressFamily(t *testing.T) {
	if got := udpListenNetwork(&net.UDPAddr{IP: net.IPv4(8, 8, 8, 8)}); got != "udp4" {
		t.Fatalf("IPv4 network=%q want udp4", got)
	}
	if got := udpListenNetwork(&net.UDPAddr{IP: net.ParseIP("2001:db8::1")}); got != "udp6" {
		t.Fatalf("IPv6 network=%q want udp6", got)
	}
	if got := udpListenNetwork(&net.UDPAddr{}); got != "udp" {
		t.Fatalf("unspecified network=%q want udp", got)
	}
}

func dnsNameWireForTest(name dns.Name) ([]byte, error) {
	var out []byte
	for _, label := range name {
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	return append(out, 0), nil
}
