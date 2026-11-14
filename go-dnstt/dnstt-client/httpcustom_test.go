package main

import (
	"bytes"
	"encoding/base32"
	"testing"

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
	// DNS question name at offset 12 carries "mzxw6.test.example".
	// NS RDATA is a compression pointer back to the encoded carrier.
	zone, err := dns.ParseName("test.example")
	if err != nil {
		t.Fatal(err)
	}
	owner, _ := dns.ParseName("mzxw6.test.example")
	msg := &dns.Message{
		Flags: 0x8180,
		Answer: []dns.RR{{
			Name: owner, Type: httpCustomQTypeNS, Class: dns.ClassIN,
			Data: []byte{0xc0, 0x0c}, RDataOffset: 0,
		}},
	}
	wire := make([]byte, 12)
	copy(wire, []byte{0, 1, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0})
	qname, _ := dns.ParseName("mzxw6.test.example")
	wireName, _ := dnsNameWireForTest(qname)
	wire = append(wire, wireName...)
	wire = append(wire, 0, 2, 0, 1)
	// Compression pointer points to the start of the question name (offset 12).
	rrStart := len(wire)
	wire = append(wire, 0xc0, 0x0c, 0, 2, 0, 1, 0, 0, 0, 0, 0, 2, 0xc0, 0x0c)
	msg.Answer[0].RDataOffset = rrStart + 12
	decoded, err := decodeHTTPcustomNameCarrier(wire, msg.Answer[0], httpCustomQTypeNS, zone)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString("MZXW6")
	if !bytes.Equal(decoded, want) {
		t.Fatalf("compressed name payload mismatch: %x want %x", decoded, want)
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
