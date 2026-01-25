package netstack

/*
#include <stdlib.h>
#include <stdint.h>

// Callback type for returning packets to Swift
typedef void (*ReturnPacketCallback)(void* context, const uint8_t* data, size_t len);

// Helper function to invoke the callback (can't call function pointers directly from Go)
static inline void invokeCallback(ReturnPacketCallback cb, void* ctx, const uint8_t* data, size_t len) {
    if (cb != NULL) {
        cb(ctx, data, len);
    }
}
*/
import "C"
import (
	"sync"
	"unsafe"
)

// Global registry for stack instances
var (
	stacksMu   sync.RWMutex
	stacks     = make(map[uint64]*Stack)
	nextID     uint64 = 1
	callbacks  = make(map[uint64]C.ReturnPacketCallback)
	contexts   = make(map[uint64]unsafe.Pointer)
)

//export NetstackCreate
// NetstackCreate creates a new netstack instance.
// Returns a handle (>0) on success, 0 on failure.
// gatewayIP should be like "10.200.0.1"
func NetstackCreate(gatewayIP *C.char, mtu C.uint32_t) C.uint64_t {
	cfg := Config{
		GatewayIP: C.GoString(gatewayIP),
		MTU:       uint32(mtu),
	}

	stack, err := NewStack(cfg)
	if err != nil {
		return 0
	}

	stacksMu.Lock()
	id := nextID
	nextID++
	stacks[id] = stack
	stacksMu.Unlock()

	return C.uint64_t(id)
}

//export NetstackSetCallback
// NetstackSetCallback sets the callback for returning packets.
// context is passed back to the callback (typically a Swift object pointer).
func NetstackSetCallback(handle C.uint64_t, callback C.ReturnPacketCallback, context unsafe.Pointer) {
	stacksMu.Lock()
	stack, ok := stacks[uint64(handle)]
	if ok {
		callbacks[uint64(handle)] = callback
		contexts[uint64(handle)] = context

		// Set up the Go callback that calls the C callback
		stack.SetReturnCallback(func(packet []byte) {
			stacksMu.RLock()
			cb := callbacks[uint64(handle)]
			ctx := contexts[uint64(handle)]
			stacksMu.RUnlock()

			if cb != nil && len(packet) > 0 {
				C.invokeCallback(cb, ctx, (*C.uint8_t)(unsafe.Pointer(&packet[0])), C.size_t(len(packet)))
			}
		})
	}
	stacksMu.Unlock()
}

//export NetstackStart
// NetstackStart starts the netstack processing.
func NetstackStart(handle C.uint64_t) C.int {
	stacksMu.RLock()
	stack, ok := stacks[uint64(handle)]
	stacksMu.RUnlock()

	if !ok {
		return -1
	}

	stack.Start()
	return 0
}

//export NetstackStop
// NetstackStop stops and destroys the netstack instance.
func NetstackStop(handle C.uint64_t) {
	stacksMu.Lock()
	stack, ok := stacks[uint64(handle)]
	if ok {
		delete(stacks, uint64(handle))
		delete(callbacks, uint64(handle))
		delete(contexts, uint64(handle))
	}
	stacksMu.Unlock()

	if ok {
		stack.Stop()
	}
}

//export NetstackInjectPacket
// NetstackInjectPacket injects a raw IP packet into the stack.
// Returns 0 on success, -1 on error.
func NetstackInjectPacket(handle C.uint64_t, data *C.uint8_t, len C.size_t) C.int {
	stacksMu.RLock()
	stack, ok := stacks[uint64(handle)]
	stacksMu.RUnlock()

	if !ok {
		return -1
	}

	// Copy packet data from C memory
	packet := C.GoBytes(unsafe.Pointer(data), C.int(len))

	if err := stack.InjectPacket(packet); err != nil {
		return -1
	}

	return 0
}

//export NetstackGetStats
// NetstackGetStats returns statistics about the stack.
// Writes to the provided pointers.
func NetstackGetStats(handle C.uint64_t, tcpConns *C.uint32_t, udpConns *C.uint32_t) C.int {
	stacksMu.RLock()
	stack, ok := stacks[uint64(handle)]
	stacksMu.RUnlock()

	if !ok {
		return -1
	}

	stack.mu.RLock()
	*tcpConns = C.uint32_t(len(stack.tcpConns))
	*udpConns = C.uint32_t(len(stack.udpConns))
	stack.mu.RUnlock()

	return 0
}

// Required for cgo to generate the C header
func main() {}
