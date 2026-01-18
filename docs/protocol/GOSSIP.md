# Gossip Protocol

How information propagates through the Omerta network.

## Overview

Peers exchange information during keepalives. This document covers:
1. What gets gossiped
2. How propagation works
3. Deduplication
4. Chain records vs local storage

---

## What Gets Gossiped

Multi-signed results that need network-wide visibility:

| Type | Description | Signers |
|------|-------------|---------|
| LOCK_RESULT | Escrow lock completed | Witnesses + Consumer |
| TOPUP_RESULT | Escrow top-up completed | Witnesses + Consumer |
| SETTLEMENT_RESULT | Escrow settled | Witnesses |
| ATTESTATION | Session verification result | Cabal members |

These are self-verifying - any recipient can check the signatures without contacting the signers.

---

## Propagation Mechanism

Each piece of new information propagates to N peers, then stops.

### On Receiving New Info

```
receive(info):
  key = hash1(info)
  value = hash2(info)

  if seen_table.get(key) == value:
    return  # Already processed, drop

  seen_table[key] = value
  store(info)
  propagation_queue.add(info, count=N)
```

### During Keepalive

```
keepalive(peer):
  # Normal keepalive content...

  # Attach gossip items
  for item in propagation_queue:
    if item.count > 0:
      send(peer, item.info)
      item.count -= 1

  # Clean up exhausted items
  propagation_queue.remove_where(count == 0)
```

### Parameters

| Parameter | Description | Suggested Value |
|-----------|-------------|-----------------|
| N | Propagation fanout (peers per item) | 3-5 |
| seen_table max size | Memory bound for dedup table | 100,000 entries |

---

## Deduplication

### Dual-Hash Table Approach

Use two independent hash functions to eliminate false positives:

```
seen_table: Map<hash1(data), hash2(data)>

check_seen(data):
  key = hash1(data)
  expected = hash2(data)
  return seen_table.get(key) == expected

mark_seen(data):
  seen_table[hash1(data)] = hash2(data)
  if len(seen_table) > MAX_SIZE:
    evict_oldest()
```

**Properties:**
- No false positives (negligible probability)
  - Would require `hash1(A) == hash1(B)` AND `hash2(A) == hash2(B)` for different A, B
  - Probability is product of two independent collision probabilities
- False negatives possible only from eviction
  - Old entry evicted, item returns, we've forgotten
  - Results in redundant propagation (harmless for gossip)

### Why This Works

| Scenario | hash1 | hash2 | Result |
|----------|-------|-------|--------|
| Same data, seen before | matches key | matches value | Correctly identified as seen |
| Different data, hash1 collision | matches key | different value | Correctly identified as new |
| Same data, was evicted | key not present | n/a | False negative, re-propagate (ok) |

The dual-hash approach converts hash1 collisions from false positives into correct rejections, at the cost of storing one hash value per entry.

---

## Chain Records vs Local Storage

### On-Chain (Permanent)

**PEER_HASH records** - recorded only when:
1. Peer's chain head has changed since last record
2. Minimum interval has passed (rate limiting)

```
PEER_HASH {
  peer: peer_id
  hash: chain_head_hash
  timestamp: uint
}
```

These create the DAG structure and provide historical proof of what you knew and when.

### Local Storage (Ephemeral)

**Recent peer state** - high-frequency updates, not persisted to chain:

```
local_peer_cache: Map<peer_id, PeerState>

PeerState {
  last_hash: hash
  last_seen: timestamp
  recent_hashes: [(hash, timestamp)]  # Ring buffer
}
```

**Gossip state:**

```
seen_table: Map<hash, bool>           # Deduplication
propagation_queue: [(info, count)]    # Pending gossip
received_results: Map<hash, Result>   # Multi-signed results we know about
```

---

## Propagation Properties

### Convergence

With N=3 fanout and random peer selection:
- Info reaches most of network in O(log(network_size)) keepalive rounds
- Probabilistic, not guaranteed (some peers may miss info)
- Missing info can be recovered via State Query (Transaction 03)

### Bandwidth

Per keepalive, gossip adds:
- Header: which items are attached
- Items: full multi-signed results

Bounded by:
- propagation_queue size (items waiting to be sent)
- Per-item count (N sends then done)

### Consistency

Gossip is best-effort. For critical operations:
1. Direct participants receive info synchronously (in the transaction)
2. Gossip spreads to non-participants over time
3. State Query provides on-demand verification
4. State Audit provides full reconstruction if needed

---

## Integration with Keepalives

Keepalives already happen regularly between peers. Gossip piggybacks:

```
KEEPALIVE {
  sender: peer_id
  my_chain_head: hash
  timestamp: uint
  signature: bytes

  # Gossip payload
  gossip_items: [GossipItem]
}

GossipItem {
  type: LOCK_RESULT | TOPUP_RESULT | SETTLEMENT_RESULT | ATTESTATION
  payload: bytes  # The multi-signed result
}
```

Receiver processes gossip items using the propagation mechanism above.

---

## Security Considerations

### Spam Prevention

- Only gossip multi-signed items (require witness quorum to create)
- Rate limit gossip items per keepalive
- Propagation count bounds how far any item travels

### Malformed Items

- Verify signatures before storing/propagating
- Drop items with invalid signatures
- Don't add to seen_table if invalid (allow retry with valid version)

### Eclipse Attacks

If an attacker controls all your peers, they can prevent gossip from reaching you. Mitigations:
- Diverse peer selection
- Periodic State Query to verify you're not missing critical info
- Health checks (Transaction 05) detect state divergence
