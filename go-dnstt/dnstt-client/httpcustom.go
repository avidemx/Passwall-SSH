package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"strings"

	"www.bamsoftware.com/git/dnstt.git/dns"
)

const (
	httpCustomQTypeNS    uint16 = 2
	httpCustomQTypeCNAME uint16 = 5
	httpCustomQTypeNULL  uint16 = 10
	httpCustomQTypeMX    uint16 = 15
	httpCustomQTypeTXT   uint16 = 16
	httpCustomQTypeSRV   uint16 = 33
)

var httpCustomCompactEncoding = base64.NewEncoding(
	"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789+",
).WithPadding(base64.NoPadding)

var httpCustomBase32Encoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// logHTTPcustomKCP dumps bounded packet bytes and parses standard KCP
// segment headers. It is diagnostic only and does not modify packet data.
func logHTTPcustomKCP(direction string, packet []byte) {
	preview := packet
	if len(preview) > 128 {
		preview = preview[:128]
	}
	log.Printf("HTTPCustom KCP %s datagram=%dB hex=%x", direction, len(packet), preview)

	const headerSize = 24
	for offset, index := 0, 0; offset < len(packet); index++ {
		remaining := len(packet) - offset
		if remaining < headerSize {
			log.Printf("HTTPCustom KCP %s trailing=%dB hex=%x", direction, remaining, packet[offset:])
			return
		}
		segment := packet[offset:]
		conv := binary.LittleEndian.Uint32(segment[0:4])
		cmd := segment[4]
		frg := segment[5]
		wnd := binary.LittleEndian.Uint16(segment[6:8])
		ts := binary.LittleEndian.Uint32(segment[8:12])
		sn := binary.LittleEndian.Uint32(segment[12:16])
		una := binary.LittleEndian.Uint32(segment[16:20])
		length := binary.LittleEndian.Uint32(segment[20:24])
		if uint64(length) > uint64(remaining-headerSize) {
			log.Printf("HTTPCustom KCP %s segment[%d] invalid-length conv=%08x cmd=%02x frg=%d wnd=%d ts=%d sn=%d una=%d len=%d remaining=%d",
				direction, index, conv, cmd, frg, wnd, ts, sn, una, length, remaining-headerSize)
			return
		}
		log.Printf("HTTPCustom KCP %s segment[%d] conv=%08x cmd=%02x frg=%d wnd=%d ts=%d sn=%d una=%d len=%d",
			direction, index, conv, cmd, frg, wnd, ts, sn, una, length)
		offset += headerSize + int(length)
	}
}

// parseHTTPcustomQType parses the fixed HTTP Custom DNS resource-record mode.
// Auto is deliberately not mapped to QTYPE 0; it requires authenticated probing.
func parseHTTPcustomQType(s string) (uint16, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "ns", "2":
		return httpCustomQTypeNS, nil
	case "cname", "5":
		return httpCustomQTypeCNAME, nil
	case "null", "10":
		return httpCustomQTypeNULL, nil
	case "mx", "15":
		return httpCustomQTypeMX, nil
	case "txt", "16":
		return httpCustomQTypeTXT, nil
	case "srv", "33":
		return httpCustomQTypeSRV, nil
	case "auto", "0":
		return 0, fmt.Errorf("HTTP Custom Auto mode is not enabled yet; choose ns, cname, null, mx, txt, or srv")
	default:
		return 0, fmt.Errorf("unsupported HTTP Custom QTYPE %q", s)
	}
}

// generateHTTPcustomDNSID creates a fresh DNS transaction ID independently
// from the ClientID and the per-query QNAME padding, as observed in the native
// HTTP Custom PCAP capture.
func generateHTTPcustomDNSID() (uint16, error) {
	var raw [2]byte
	if _, err := io.ReadFull(rand.Reader, raw[:]); err != nil {
		return 0, fmt.Errorf("generate HTTP Custom DNS transaction ID: %w", err)
	}
	return binary.BigEndian.Uint16(raw[:]), nil
}

// encodeHTTPcustomFrame mirrors the native HTTP Custom QNAME framing.
// Data: ClientID[8] | E3 | random padding[3] | packet length[1] | packet.
// Poll: ClientID[8] | E8 | random padding[8].
func encodeHTTPcustomFrame(clientID, packet, randomPadding []byte) ([]byte, error) {
	if len(clientID) != 8 {
		return nil, fmt.Errorf("HTTP Custom ClientID must be exactly 8 bytes")
	}
	if len(packet) >= 224 {
		return nil, fmt.Errorf("HTTP Custom packet length %d exceeds 223-byte limit", len(packet))
	}

	paddingLen := numPadding
	if len(packet) == 0 {
		paddingLen = numPaddingForPoll
	}
	if len(randomPadding) != paddingLen {
		return nil, fmt.Errorf("HTTP Custom padding must be %d bytes for this frame, got %d", paddingLen, len(randomPadding))
	}

	var frame bytes.Buffer
	frame.Write(clientID)
	frame.WriteByte(byte(224 + paddingLen))
	frame.Write(randomPadding)
	if len(packet) > 0 {
		frame.WriteByte(byte(len(packet)))
		frame.Write(packet)
	}
	return frame.Bytes(), nil
}

func encodeHTTPcustomQNAME(frame []byte, qtype uint16, domain dns.Name) (dns.Name, error) {
	var encoded []byte
	if qtype == httpCustomQTypeNULL {
		encoded = make([]byte, httpCustomCompactEncoding.EncodedLen(len(frame)))
		httpCustomCompactEncoding.Encode(encoded, frame)
	} else {
		encoded = make([]byte, httpCustomBase32Encoding.EncodedLen(len(frame)))
		httpCustomBase32Encoding.Encode(encoded, frame)
		encoded = bytes.ToLower(encoded)
	}

	labels := chunks(encoded, 63)
	labels = append(labels, domain...)
	return dns.NewName(labels)
}

func (c *DNSPacketConn) sendHTTPcustom(transport net.PacketConn, packet []byte, addr net.Addr) error {
	paddingLen := numPadding
	if len(packet) == 0 {
		paddingLen = numPaddingForPoll
	}
	randomPadding := make([]byte, paddingLen)
	if _, err := io.ReadFull(rand.Reader, randomPadding); err != nil {
		return fmt.Errorf("generate HTTP Custom QNAME padding: %w", err)
	}

	logHTTPcustomKCP("TX", packet)
	frame, err := encodeHTTPcustomFrame(c.clientID[:], packet, randomPadding)
	if err != nil {
		return err
	}

	qname, err := encodeHTTPcustomQNAME(frame, c.qtype, c.domain)
	if err != nil {
		return fmt.Errorf("encode HTTP Custom QNAME: %w", err)
	}

	id, err := generateHTTPcustomDNSID()
	if err != nil {
		return err
	}
	query := &dns.Message{
		ID:    id,
		Flags: 0x0100,
		Question: []dns.Question{{
			Name:  qname,
			Type:  c.qtype,
			Class: dns.ClassIN,
		}},
		Additional: []dns.RR{{
			Name:  dns.Name{},
			Type:  dns.RRTypeOPT,
			Class: 4096,
			TTL:   0,
			Data:  []byte{},
		}},
	}
	wire, err := query.WireFormat()
	if err != nil {
		return fmt.Errorf("encode HTTP Custom DNS message: %w", err)
	}
	_, err = transport.WriteTo(wire, addr)
	if err == nil {
		c.httpCustomSendCount++
		count := c.httpCustomSendCount
		if count <= 30 || count%50 == 0 {
			log.Printf("HTTPCustom TX #%d id=%04x id_source=independent-random client_id=%s marker=%02x padding=%x qtype=%d payload=%dB frame=%dB qname=%s dns=%dB",
				count, id, c.clientID.String(), frame[8], randomPadding, c.qtype, len(packet), len(frame), qname.String(), len(wire))
		}
	}
	return err
}

func decodeHTTPcustomWireName(wire []byte, offset int) ([]string, error) {
	if offset < 0 || offset >= len(wire) {
		return nil, fmt.Errorf("DNS name offset %d outside packet", offset)
	}
	var labels []string
	pos := offset
	visited := make(map[int]bool)
	jumped := false
	steps := 0

	for {
		if pos < 0 || pos >= len(wire) {
			return nil, fmt.Errorf("truncated DNS name")
		}
		steps++
		if steps > 128 {
			return nil, fmt.Errorf("DNS compression pointer loop or excessive labels")
		}
		length := int(wire[pos])
		switch {
		case length == 0:
			return labels, nil
		case length&0xc0 == 0xc0:
			if pos+1 >= len(wire) {
				return nil, fmt.Errorf("truncated DNS compression pointer")
			}
			pointer := ((length & 0x3f) << 8) | int(wire[pos+1])
			if pointer >= len(wire) || visited[pointer] {
				return nil, fmt.Errorf("invalid or cyclic DNS compression pointer")
			}
			visited[pointer] = true
			pos = pointer
			jumped = true
		case length&0xc0 != 0:
			return nil, fmt.Errorf("unsupported DNS label type")
		default:
			if length > 63 || pos+1+length > len(wire) {
				return nil, fmt.Errorf("truncated or oversized DNS label")
			}
			labels = append(labels, string(wire[pos+1:pos+1+length]))
			pos += 1 + length
		}
		_ = jumped
	}
}

func decodeHTTPcustomNameCarrier(wire []byte, rr dns.RR, qtype uint16, domain dns.Name) ([]byte, error) {
	skip := 0
	switch qtype {
	case httpCustomQTypeNS, httpCustomQTypeCNAME:
	case httpCustomQTypeMX:
		skip = 2
	case httpCustomQTypeSRV:
		skip = 6
	default:
		return nil, fmt.Errorf("QTYPE %d is not a name carrier", qtype)
	}
	if len(rr.Data) <= skip {
		return nil, fmt.Errorf("name-carrier RDATA is too short")
	}
	offset := rr.RDataOffset + skip
	labels, err := decodeHTTPcustomWireName(wire, offset)
	if err != nil {
		return nil, err
	}
	if len(domain) > 0 && len(labels) >= len(domain) {
		matches := true
		start := len(labels) - len(domain)
		for i, suffixLabel := range domain {
			if !bytes.Equal(bytes.ToLower([]byte(labels[start+i])), bytes.ToLower(suffixLabel)) {
				matches = false
				break
			}
		}
		if matches {
			labels = labels[:start]
		}
	}
	if len(labels) == 0 {
		return nil, fmt.Errorf("empty HTTP Custom name carrier")
	}

	// CNAME has a dedicated upper-case normalization path in HTTP Custom.
	// The other name-carrier records also normalize Base32's alphabetic
	// digits for case-insensitive DNS label transport.
	var encoded strings.Builder
	for _, label := range labels {
		for _, ch := range label {
			if ch >= 'a' && ch <= 'z' {
				ch -= 'a' - 'A'
			}
			encoded.WriteByte(byte(ch))
		}
	}
	payload := make([]byte, httpCustomBase32Encoding.DecodedLen(encoded.Len()))
	n, err := httpCustomBase32Encoding.Decode(payload, []byte(encoded.String()))
	if err != nil {
		return nil, fmt.Errorf("decode QTYPE %d Base32 name carrier: %w", qtype, err)
	}
	return payload[:n], nil
}

func decodeHTTPcustomAnswer(wire []byte, resp *dns.Message, domain dns.Name, qtype uint16) []byte {
	if resp.Flags&0x8000 == 0 || resp.Flags&0x000f != dns.RcodeNoError {
		return nil
	}
	var payload []byte
	for _, answer := range resp.Answer {
		if answer.Class != dns.ClassIN || answer.Type != qtype {
			continue
		}
		if _, ok := answer.Name.TrimSuffix(domain); !ok {
			continue
		}

		var decoded []byte
		var err error
		switch qtype {
		case httpCustomQTypeNULL:
			decoded = answer.Data
		case httpCustomQTypeTXT:
			decoded, err = dns.DecodeRDataTXT(answer.Data)
		case httpCustomQTypeNS, httpCustomQTypeCNAME, httpCustomQTypeMX, httpCustomQTypeSRV:
			decoded, err = decodeHTTPcustomNameCarrier(wire, answer, qtype, domain)
		default:
			continue
		}
		if err == nil {
			payload = append(payload, decoded...)
		}
	}
	return payload
}

func httpCustomTransportMTU(domain dns.Name, qtype uint16) int {
	// Available encoded label bytes after accounting for the zone suffix,
	// 255-byte DNS wire-name limit, and one length octet per label.
	capacity := 255 - 1
	for _, label := range domain {
		capacity -= len(label) + 1
	}
	if capacity <= 0 {
		return 0
	}
	encodedCapacity := capacity * 63 / 64
	var frameCapacity int
	if qtype == httpCustomQTypeNULL {
		frameCapacity = encodedCapacity * 3 / 4
	} else {
		frameCapacity = encodedCapacity * 5 / 8
	}
	// ClientID (8) + E3 marker (1) + data padding (3) + length (1).
	mtu := frameCapacity - 13
	if mtu > 223 {
		mtu = 223
	}
	return mtu
}
