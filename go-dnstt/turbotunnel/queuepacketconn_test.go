package turbotunnel

import (
	"testing"
)

func TestQueuePacketConnWithQueueSize(t *testing.T) {
	const requested = 512
	conn := NewQueuePacketConnWithQueueSize(DummyAddr{}, 0, requested)
	defer conn.Close()

	if got := cap(conn.recvQueue); got != requested {
		t.Fatalf("incoming queue capacity=%d want %d", got, requested)
	}
	outgoing := conn.OutgoingQueue(DummyAddr{})
	if got := cap(outgoing); got != requested {
		t.Fatalf("outgoing queue capacity=%d want %d", got, requested)
	}
}

func TestQueuePacketConnQueueSizeBounds(t *testing.T) {
	conn := NewQueuePacketConnWithQueueSize(DummyAddr{}, 0, MaxQueueSize+1)
	defer conn.Close()
	if got := cap(conn.recvQueue); got != MaxQueueSize {
		t.Fatalf("oversized queue capacity=%d want %d", got, MaxQueueSize)
	}

	minimum := NewQueuePacketConnWithQueueSize(DummyAddr{}, 0, 64)
	defer minimum.Close()
	if got := cap(minimum.recvQueue); got != QueueSize {
		t.Fatalf("undersized queue capacity=%d want minimum %d", got, QueueSize)
	}
}

func TestQueuePacketConnCountsDrops(t *testing.T) {
	const queueSize = QueueSize
	conn := NewQueuePacketConnWithQueueSize(DummyAddr{}, 0, queueSize)
	defer conn.Close()

	for i := 0; i < queueSize+1; i++ {
		conn.QueueIncoming([]byte{byte(i)}, DummyAddr{})
	}
	if incoming, outgoing := conn.QueueDropCounts(); incoming != 1 || outgoing != 0 {
		t.Fatalf("drop counters after incoming overflow=(%d,%d), want (1,0)", incoming, outgoing)
	}

	for i := 0; i < queueSize+1; i++ {
		if _, err := conn.WriteTo([]byte{byte(i)}, DummyAddr{}); err != nil {
			t.Fatalf("WriteTo %d: %v", i, err)
		}
	}
	if incoming, outgoing := conn.QueueDropCounts(); incoming != 1 || outgoing != 1 {
		t.Fatalf("drop counters after both overflows=(%d,%d), want (1,1)", incoming, outgoing)
	}
}
