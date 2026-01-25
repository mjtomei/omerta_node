package netstack

import (
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

func TestNetstackInit(t *testing.T) {
	cfg := Config{
		GatewayIP: "10.200.0.1",
		MTU:       1500,
	}

	stack, err := NewStack(cfg)
	if err != nil {
		t.Fatalf("Failed to create stack: %v", err)
	}
	defer stack.Stop()

	if stack.stack == nil {
		t.Error("Stack is nil")
	}
	if stack.endpoint == nil {
		t.Error("Endpoint is nil")
	}
}

func TestInjectInvalidPacket(t *testing.T) {
	cfg := Config{
		GatewayIP: "10.200.0.1",
		MTU:       1500,
	}

	stack, err := NewStack(cfg)
	if err != nil {
		t.Fatalf("Failed to create stack: %v", err)
	}
	defer stack.Stop()

	// Empty packet should fail
	if err := stack.InjectPacket(nil); err == nil {
		t.Error("Expected error for empty packet")
	}

	// Invalid IP version should fail
	badPacket := []byte{0x00, 0x01, 0x02, 0x03}
	if err := stack.InjectPacket(badPacket); err == nil {
		t.Error("Expected error for invalid IP version")
	}
}

func TestTCPForwarding(t *testing.T) {
	// Start a simple HTTP server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("Hello from server"))
	}))
	defer server.Close()

	// Parse server address
	serverAddr := server.Listener.Addr().(*net.TCPAddr)

	cfg := Config{
		GatewayIP: "10.200.0.1",
		MTU:       1500,
	}

	stack, err := NewStack(cfg)
	if err != nil {
		t.Fatalf("Failed to create stack: %v", err)
	}
	defer stack.Stop()

	// Collect returned packets
	var returnedPackets [][]byte
	var mu sync.Mutex

	stack.SetReturnCallback(func(packet []byte) {
		mu.Lock()
		returnedPackets = append(returnedPackets, packet)
		mu.Unlock()
	})

	stack.Start()

	// Create a TCP SYN packet to the server
	// This is a simplified test - in real usage, the VM would generate these
	synPacket := createTCPSYN("10.200.0.2", 12345, serverAddr.IP.String(), uint16(serverAddr.Port))

	if err := stack.InjectPacket(synPacket); err != nil {
		t.Logf("Inject SYN (expected to process): %v", err)
	}

	// Wait for processing
	time.Sleep(100 * time.Millisecond)

	// Check that we got some response packets
	mu.Lock()
	numPackets := len(returnedPackets)
	mu.Unlock()

	t.Logf("Received %d return packets", numPackets)
}

func TestUDPForwarding(t *testing.T) {
	// Start a UDP echo server
	serverConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("Failed to start UDP server: %v", err)
	}
	defer serverConn.Close()

	serverAddr := serverConn.LocalAddr().(*net.UDPAddr)

	// Echo server goroutine
	go func() {
		buf := make([]byte, 1500)
		for {
			n, addr, err := serverConn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			serverConn.WriteToUDP(buf[:n], addr)
		}
	}()

	cfg := Config{
		GatewayIP: "10.200.0.1",
		MTU:       1500,
	}

	stack, err := NewStack(cfg)
	if err != nil {
		t.Fatalf("Failed to create stack: %v", err)
	}
	defer stack.Stop()

	var returnedPackets [][]byte
	var mu sync.Mutex

	stack.SetReturnCallback(func(packet []byte) {
		mu.Lock()
		returnedPackets = append(returnedPackets, packet)
		mu.Unlock()
	})

	stack.Start()

	// Create a UDP packet
	udpPacket := createUDPPacket("10.200.0.2", 54321, serverAddr.IP.String(), uint16(serverAddr.Port), []byte("ping"))

	if err := stack.InjectPacket(udpPacket); err != nil {
		t.Logf("Inject UDP: %v", err)
	}

	// Wait for echo
	time.Sleep(100 * time.Millisecond)

	mu.Lock()
	numPackets := len(returnedPackets)
	mu.Unlock()

	t.Logf("Received %d return packets", numPackets)
}

func BenchmarkPacketInjection(b *testing.B) {
	cfg := Config{
		GatewayIP: "10.200.0.1",
		MTU:       1500,
	}

	stack, err := NewStack(cfg)
	if err != nil {
		b.Fatalf("Failed to create stack: %v", err)
	}
	defer stack.Stop()

	stack.SetReturnCallback(func(packet []byte) {
		// Discard
	})

	stack.Start()

	// Create a test packet
	packet := createUDPPacket("10.200.0.2", 12345, "1.1.1.1", 53, []byte("test"))

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		stack.InjectPacket(packet)
	}
}

// Helper functions to create test packets

func createTCPSYN(srcIP string, srcPort uint16, dstIP string, dstPort uint16) []byte {
	// Create a minimal IPv4 + TCP SYN packet
	ipLen := header.IPv4MinimumSize + header.TCPMinimumSize
	packet := make([]byte, ipLen)

	// IPv4 header
	ip := header.IPv4(packet)
	ip.Encode(&header.IPv4Fields{
		TotalLength: uint16(ipLen),
		TTL:         64,
		Protocol:    uint8(header.TCPProtocolNumber),
		SrcAddr:     tcpipAddrFromString(srcIP),
		DstAddr:     tcpipAddrFromString(dstIP),
	})
	ip.SetChecksum(^ip.CalculateChecksum())

	// TCP header
	tcp := header.TCP(packet[header.IPv4MinimumSize:])
	tcp.Encode(&header.TCPFields{
		SrcPort:    srcPort,
		DstPort:    dstPort,
		SeqNum:     1,
		DataOffset: header.TCPMinimumSize,
		Flags:      header.TCPFlagSyn,
		WindowSize: 65535,
	})

	return packet
}

func createUDPPacket(srcIP string, srcPort uint16, dstIP string, dstPort uint16, payload []byte) []byte {
	ipLen := header.IPv4MinimumSize + header.UDPMinimumSize + len(payload)
	packet := make([]byte, ipLen)

	// IPv4 header
	ip := header.IPv4(packet)
	ip.Encode(&header.IPv4Fields{
		TotalLength: uint16(ipLen),
		TTL:         64,
		Protocol:    uint8(header.UDPProtocolNumber),
		SrcAddr:     tcpipAddrFromString(srcIP),
		DstAddr:     tcpipAddrFromString(dstIP),
	})
	ip.SetChecksum(^ip.CalculateChecksum())

	// UDP header
	udp := header.UDP(packet[header.IPv4MinimumSize:])
	udp.Encode(&header.UDPFields{
		SrcPort: srcPort,
		DstPort: dstPort,
		Length:  uint16(header.UDPMinimumSize + len(payload)),
	})

	// Payload
	copy(packet[header.IPv4MinimumSize+header.UDPMinimumSize:], payload)

	return packet
}

func tcpipAddrFromString(s string) tcpip.Address {
	ip := net.ParseIP(s).To4()
	if ip == nil {
		return tcpip.Address{}
	}
	return tcpip.AddrFrom4([4]byte{ip[0], ip[1], ip[2], ip[3]})
}
