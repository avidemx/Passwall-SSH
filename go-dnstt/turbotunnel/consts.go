// Package turbotunnel is facilities for embedding packet-based reliability
// protocols inside other protocols.
//
// https://github.com/net4people/bbs/issues/9
package turbotunnel

import "errors"

// QueueSize is the default size of send and receive queues in QueuePacketConn
// and RemoteMap. HTTP Custom sessions may request a larger per-session queue
// without changing the standard DNSTT default.
const QueueSize = 128

// MaxQueueSize bounds per-session queue allocations. The HTTP Custom KCP
// window is currently capped at the same value.
const MaxQueueSize = 4096

func normalizeQueueSize(queueSize int) int {
	if queueSize < QueueSize {
		return QueueSize
	}
	if queueSize > MaxQueueSize {
		return MaxQueueSize
	}
	return queueSize
}

var errClosedPacketConn = errors.New("operation on closed connection")
var errNotImplemented = errors.New("not implemented")

// DummyAddr is a placeholder net.Addr, for when a programming interface
// requires a net.Addr but there is none relevant. All DummyAddrs compare equal
// to each other.
type DummyAddr struct{}

func (addr DummyAddr) Network() string { return "dummy" }
func (addr DummyAddr) String() string  { return "dummy" }
