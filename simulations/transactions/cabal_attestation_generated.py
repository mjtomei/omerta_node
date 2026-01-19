"""
Transaction 01: Cabal Attestation

Witnesses verify VM allocation, monitor session, and attest to service delivery

GENERATED FROM transaction.omt
"""

from enum import Enum, auto
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Any

from ..chain.primitives import (
    Chain, Block, BlockType,
    hash_data, sign, verify_sig, generate_id, random_bytes
)

try:
    from omerta.native.vm_connectivity import check_consumer_connected, check_vm_connectivity
except ImportError:
    from simulations.native.vm_connectivity import check_consumer_connected, check_vm_connectivity


# =============================================================================
# Parameters
# =============================================================================

VM_ALLOCATION_TIMEOUT = 300  # Provider must allocate VM within 5 min of lock (seconds)
CONNECTIVITY_CHECK_TIMEOUT = 60  # Witnesses must verify connectivity within 1 min (seconds)
CONNECTIVITY_VOTE_TIMEOUT = 30  # Time to collect connectivity votes (seconds)
ABORT_VOTE_TIMEOUT = 30  # Time to collect abort votes (seconds)
MONITORING_CHECK_INTERVAL = 60  # Periodic VM health check interval (seconds)
MISUSE_INVESTIGATION_TIMEOUT = 120  # Time to investigate misuse accusation (seconds)
CONNECTIVITY_THRESHOLD = 0.67  # Fraction of witnesses that must verify connectivity (fraction)
ABORT_THRESHOLD = 0.67  # Fraction needed to abort session (fraction)
ATTESTATION_THRESHOLD = 3  # Minimum witnesses for valid attestation (count)
WITNESS_COUNT = 5  # Number of witnesses (from escrow lock) (count)
MIN_HIGH_TRUST_WITNESSES = 2  # Minimum high-trust witnesses required (count)
MAX_PRIOR_INTERACTIONS = 3  # Maximum prior interactions with witness (count)

# =============================================================================
# Enums
# =============================================================================

class TerminationReason(Enum):
    """Reasons for session termination"""
    COMPLETED_NORMAL = auto()
    CONSUMER_REQUEST = auto()
    PROVIDER_VOLUNTARY = auto()
    VM_DIED = auto()
    TIMEOUT = auto()
    CONSUMER_MISUSE = auto()
    ALLOCATION_FAILED = auto()
    CONNECTIVITY_FAILED = auto()

# =============================================================================
# Message Types
# =============================================================================

class MessageType(Enum):
    """Types of messages exchanged in this transaction."""
    VM_ALLOCATED = auto()
    VM_CANCELLED = auto()
    MISUSE_ACCUSATION = auto()
    VM_READY = auto()
    SESSION_TERMINATED = auto()
    CANCEL_REQUEST = auto()
    VM_CONNECTIVITY_VOTE = auto()
    ABORT_VOTE = auto()
    ATTESTATION_SHARE = auto()
    ATTESTATION_RESULT = auto()


@dataclass
class Message:
    """A message between actors."""
    msg_type: MessageType
    sender: str
    payload: Dict[str, Any]
    timestamp: float
    recipient: Optional[str] = None  # None means broadcast

# =============================================================================
# Actor Base Class
# =============================================================================

@dataclass
class Actor:
    """Base class for state machine actors."""
    peer_id: str
    chain: Chain
    current_time: float = 0.0

    local_store: Dict[str, Any] = field(default_factory=dict)
    message_queue: List[Message] = field(default_factory=list)
    state_history: List[Tuple[float, Any]] = field(default_factory=list)

    def store(self, key: str, value: Any):
        self.local_store[key] = value

    def load(self, key: str, default: Any = None) -> Any:
        return self.local_store.get(key, default)

    def receive_message(self, msg: Message):
        self.message_queue.append(msg)

    @staticmethod
    def _to_hashable(*args) -> dict:
        """Convert arguments to a hashable dict."""
        result = {}
        for i, arg in enumerate(args):
            if isinstance(arg, bytes):
                result[f'_{i}'] = arg.hex()
            else:
                result[f'_{i}'] = arg
        return result

    @staticmethod
    def _serialize_value(val: Any) -> Any:
        """Convert value to JSON-serializable form."""
        if isinstance(val, bytes):
            return val.hex()
        if isinstance(val, Enum):
            return val.name
        return val

    def get_messages(self, msg_type: MessageType = None) -> List[Message]:
        if msg_type is None:
            return self.message_queue
        return [m for m in self.message_queue if m.msg_type == msg_type]

    def clear_messages(self, msg_type: MessageType = None):
        if msg_type is None:
            self.message_queue = []
        else:
            self.message_queue = [m for m in self.message_queue if m.msg_type != msg_type]

    def transition_to(self, new_state):
        self.state = new_state
        self.state_history.append((self.current_time, new_state))
        self.store('state_entered_at', self.current_time)

    def tick(self, current_time: float) -> List[Message]:
        raise NotImplementedError


# =============================================================================
# Provider
# =============================================================================

class ProviderState(Enum):
    """Provider states."""
    WAITING_FOR_LOCK = auto()  # Waiting for escrow lock to complete
    VM_PROVISIONING = auto()  # Allocating VM resources
    NOTIFYING_CABAL = auto()  # Sending VM_ALLOCATED to cabal
    WAITING_FOR_VERIFICATION = auto()  # Waiting for cabal to verify connectivity
    VM_RUNNING = auto()  # Session active, VM accessible
    HANDLING_CANCEL = auto()  # Processing cancellation request
    SENDING_CANCELLATION = auto()  # Notifying cabal of termination
    WAITING_FOR_ATTESTATION = auto()  # Waiting for cabal attestation
    SESSION_COMPLETE = auto()  # Attestation received, ready for settlement
    SESSION_ABORTED = auto()  # Session was aborted before completion

@dataclass
class Provider(Actor):
    """Allocates VM, notifies cabal, handles termination"""

    state: ProviderState = ProviderState.WAITING_FOR_LOCK

    def start_session(self, session_id: str, consumer: str, witnesses: List[str], lock_result: Dict[str, Any]):
        """Called after escrow lock succeeds"""
        if self.state not in (ProviderState.WAITING_FOR_LOCK,):
            raise ValueError(f"Cannot start_session in state {self.state}")

        self.store("session_id", session_id)
        self.store("consumer", consumer)
        self.store("witnesses", witnesses)
        self.store("lock_result", lock_result)
        self.store("lock_completed_at", self.current_time)
        self.transition_to(ProviderState.VM_PROVISIONING)

    def allocate_vm(self, vm_info: Dict[str, Any]):
        """VM allocation completes"""
        if self.state not in (ProviderState.VM_PROVISIONING,):
            raise ValueError(f"Cannot allocate_vm in state {self.state}")

        self.store("vm_info", vm_info)
        self.store("vm_allocated_at", self.current_time)
        self.transition_to(ProviderState.NOTIFYING_CABAL)

    def cancel_session(self, reason: str):
        """Initiate session cancellation"""
        if self.state not in (ProviderState.VM_RUNNING,):
            raise ValueError(f"Cannot cancel_session in state {self.state}")

        self.store("reason", reason)
        self.store("termination_reason", self.load("reason"))
        self.store("cancelled_at", self.current_time)
        self.transition_to(ProviderState.HANDLING_CANCEL)

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ProviderState.WAITING_FOR_LOCK:
            pass

        elif self.state == ProviderState.VM_PROVISIONING:
            # Timeout check
            if current_time - self.load("state_entered_at", 0) > VM_ALLOCATION_TIMEOUT:
                self.store("termination_reason", TerminationReason.ALLOCATION_FAILED)
                self.transition_to(ProviderState.SESSION_ABORTED)


        elif self.state == ProviderState.NOTIFYING_CABAL:
            # Auto transition
            # Compute: vm_allocated_msg = {session_id: LOAD(session_id), provider: peer_id, consumer: LOAD(consumer), vm_info: LOAD(vm_info), allocated_at: LOAD(vm_allocated_at), lock_result_hash: HASH(LOAD(lock_result)), timestamp: NOW()}
            self.store("vm_allocated_msg", self._compute_vm_allocated_msg())
            for recipient in self.load("witnesses", []):
                msg_payload = self._build_vm_allocated_payload()
                outgoing.append(Message(
                    msg_type=MessageType.VM_ALLOCATED,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            msg_payload = self._build_vm_ready_payload()
            outgoing.append(Message(
                msg_type=MessageType.VM_READY,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("consumer"),
            ))
            self.store("notified_at", self.current_time)
            self.store("connectivity_votes", [])
            self.transition_to(ProviderState.WAITING_FOR_VERIFICATION)

        elif self.state == ProviderState.WAITING_FOR_VERIFICATION:
            # Check for VM_CONNECTIVITY_VOTE
            msgs = self.get_messages(MessageType.VM_CONNECTIVITY_VOTE)
            if msgs:
                msg = msgs[0]
                _list = self.load("connectivity_votes") or []
                _list.append(msg.payload)
                self.store("connectivity_votes", _list)
                self.transition_to(ProviderState.WAITING_FOR_VERIFICATION)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if current_time - self.load("state_entered_at", 0) > CONNECTIVITY_CHECK_TIMEOUT:
                self.store("verification_passed", True)
                self.transition_to(ProviderState.VM_RUNNING)

            # Timeout check
            if current_time - self.load("state_entered_at", 0) > CONNECTIVITY_CHECK_TIMEOUT:
                self.store("verification_passed", False)
                self.store("termination_reason", TerminationReason.CONNECTIVITY_FAILED)
                self.transition_to(ProviderState.SENDING_CANCELLATION)

            # Auto transition with guard: LENGTH (connectivity_votes) >= LENGTH (witnesses)  and count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) >= CONNECTIVITY_THRESHOLD
            if self._check_LENGTH_connectivity_votes_gte_LENGTH_witnesses_and_count_pos():
                self.store("verification_passed", True)
                self.transition_to(ProviderState.VM_RUNNING)
            # Auto transition with guard: LENGTH (connectivity_votes) >= LENGTH (witnesses)  and count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) < CONNECTIVITY_THRESHOLD
            elif self._check_LENGTH_connectivity_votes_gte_LENGTH_witnesses_and_count_pos():
                self.store("verification_passed", False)
                self.store("termination_reason", TerminationReason.CONNECTIVITY_FAILED)
                self.transition_to(ProviderState.SENDING_CANCELLATION)

        elif self.state == ProviderState.VM_RUNNING:
            # Check for CANCEL_REQUEST
            msgs = self.get_messages(MessageType.CANCEL_REQUEST)
            if msgs:
                msg = msgs[0]
                self.store("termination_reason", TerminationReason.CONSUMER_REQUEST)
                self.store("cancelled_at", self.current_time)
                self.transition_to(ProviderState.HANDLING_CANCEL)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == ProviderState.HANDLING_CANCEL:
            # Auto transition
            self.transition_to(ProviderState.SENDING_CANCELLATION)

        elif self.state == ProviderState.SENDING_CANCELLATION:
            # Auto transition
            # Compute: vm_cancelled_msg = {session_id: LOAD(session_id), provider: peer_id, cancelled_at: LOAD(cancelled_at), reason: LOAD(termination_reason), actual_duration_seconds: LOAD(cancelled_at) - LOAD(vm_allocated_at), timestamp: NOW()}
            self.store("vm_cancelled_msg", self._compute_vm_cancelled_msg())
            for recipient in self.load("witnesses", []):
                msg_payload = self._build_vm_cancelled_payload()
                outgoing.append(Message(
                    msg_type=MessageType.VM_CANCELLED,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            msg_payload = self._build_session_terminated_payload()
            outgoing.append(Message(
                msg_type=MessageType.SESSION_TERMINATED,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("consumer"),
            ))
            self.store("cancellation_sent_at", self.current_time)
            self.transition_to(ProviderState.WAITING_FOR_ATTESTATION)

        elif self.state == ProviderState.WAITING_FOR_ATTESTATION:
            # Check for ATTESTATION_RESULT
            msgs = self.get_messages(MessageType.ATTESTATION_RESULT)
            if msgs:
                msg = msgs[0]
                self.store("attestation", msg.payload.get("attestation"))
                self.transition_to(ProviderState.SESSION_COMPLETE)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == ProviderState.SESSION_COMPLETE:
            # Attestation received, ready for settlement
            pass

        elif self.state == ProviderState.SESSION_ABORTED:
            # Session was aborted before completion
            pass

        return outgoing

    def _build_vm_ready_payload(self) -> Dict[str, Any]:
        """Build payload for VM_READY message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "vm_info": self._serialize_value(self.load("vm_info")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_session_terminated_payload(self) -> Dict[str, Any]:
        """Build payload for SESSION_TERMINATED message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "reason": self._serialize_value(self.load("reason")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_vm_allocated_payload(self) -> Dict[str, Any]:
        """Build payload for VM_ALLOCATED message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "provider": self._serialize_value(self.load("provider")),
            "consumer": self._serialize_value(self.load("consumer")),
            "vm_wireguard_pubkey": self._serialize_value(self.load("vm_wireguard_pubkey")),
            "consumer_wireguard_endpoint": self._serialize_value(self.load("consumer_wireguard_endpoint")),
            "cabal_wireguard_endpoints": self._serialize_value(self.load("cabal_wireguard_endpoints")),
            "allocated_at": self._serialize_value(self.load("allocated_at")),
            "lock_result_hash": self._serialize_value(self.load("lock_result_hash")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_vm_cancelled_payload(self) -> Dict[str, Any]:
        """Build payload for VM_CANCELLED message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "provider": self._serialize_value(self.load("provider")),
            "cancelled_at": self._serialize_value(self.load("cancelled_at")),
            "reason": self._serialize_value(self.load("reason")),
            "actual_duration_seconds": self._serialize_value(self.load("actual_duration_seconds")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _check_LENGTH_connectivity_votes_gte_LENGTH_witnesses_and_count_pos(self) -> bool:
        # Schema: LENGTH (connectivity_votes) >= LENGTH (witnesses) and count_...
        return len (self.load("connectivity_votes")) >= len (self.load("witnesses")) and self._count_positive_votes (self.load("connectivity_votes")) / len (self.load("connectivity_votes")) >= CONNECTIVITY_THRESHOLD

    def _check_LENGTH_connectivity_votes_gt_0_and_count_positive_votes_conn(self) -> bool:
        # Schema: LENGTH (connectivity_votes) > 0 and count_positive_votes (co...
        return len (self.load("connectivity_votes")) > 0 and self._count_positive_votes (self.load("connectivity_votes")) / len (self.load("connectivity_votes")) >= CONNECTIVITY_THRESHOLD

    def _check_LENGTH_connectivity_votes_eq_0_or_count_positive_votes_conne(self) -> bool:
        # Schema: LENGTH (connectivity_votes) == 0 or count_positive_votes (co...
        return len (self.load("connectivity_votes")) == 0 or self._count_positive_votes (self.load("connectivity_votes")) / len (self.load("connectivity_votes")) < CONNECTIVITY_THRESHOLD

    def _check_message_sender_eq_LOAD_consumer(self) -> bool:
        # Schema: message.sender == LOAD (consumer)...
        return self.load("message").get("sender")== self.load("consumer")

    def _compute_vm_allocated_msg(self) -> Any:
        """Compute vm_allocated_msg."""
        # Schema: {session_id: LOAD(session_id), provider: peer_id, consumer: ...
        return {"session_id": self.load("session_id"), "provider": self.peer_id, "consumer": self.load("consumer"), "vm_info": self.load("vm_info"), "allocated_at": self.load("vm_allocated_at"), "lock_result_hash": hash_data(self._to_hashable(self.load("lock_result"))), "timestamp": self.current_time}

    def _compute_vm_cancelled_msg(self) -> Any:
        """Compute vm_cancelled_msg."""
        # Schema: {session_id: LOAD(session_id), provider: peer_id, cancelled_...
        return {"session_id": self.load("session_id"), "provider": self.peer_id, "cancelled_at": self.load("cancelled_at"), "reason": self.load("termination_reason"), "actual_duration_seconds": self.load("cancelled_at") - self.load("vm_allocated_at"), "timestamp": self.current_time}

    def _verify_chain_segment(self, segment: List[dict]) -> bool:
        """VERIFY_CHAIN_SEGMENT: Verify a chain segment is valid."""
        if not segment:
            return False
        # Verify hash chain integrity
        for i in range(1, len(segment)):
            if segment[i].get("previous_hash") != segment[i-1].get("block_hash"):
                return False
            # Verify sequences are consecutive
            if segment[i].get("sequence") != segment[i-1].get("sequence") + 1:
                return False
        return True

    def _chain_contains_hash(self, chain_or_segment: Any, target_hash: str) -> bool:
        """CHAIN_CONTAINS_HASH: Check if chain/segment contains a hash."""
        if isinstance(chain_or_segment, list):
            # It's a segment (list of block dicts)
            return any(b.get('block_hash') == target_hash for b in chain_or_segment)
        elif hasattr(chain_or_segment, 'contains_hash'):
            # It's a Chain object
            return chain_or_segment.contains_hash(target_hash)
        return False

    def _chain_state_at(self, chain_or_segment: Any, target_hash: str) -> Optional[Dict[str, Any]]:
        """CHAIN_STATE_AT: Extract chain state at a specific block hash."""
        if isinstance(chain_or_segment, list):
            # It's a segment - find the block and build state
            target_idx = None
            for i, block in enumerate(chain_or_segment):
                if block.get('block_hash') == target_hash:
                    target_idx = i
                    break
            if target_idx is None:
                return None
            # Build state from blocks up to target
            state = {
                "known_peers": set(),
                "peer_hashes": {},
                "balance_locks": [],
                "block_hash": target_hash,
                "sequence": target_idx,
            }
            for block in chain_or_segment[:target_idx + 1]:
                if block.get('block_type') == 'peer_hash':
                    peer = block.get('payload', {}).get('peer')
                    if peer:
                        state["known_peers"].add(peer)
                        state["peer_hashes"][peer] = block.get("payload", {}).get("hash")
                elif block.get('block_type') == 'balance_lock':
                    state["balance_locks"].append(block.get("payload", {}))
            state["known_peers"] = list(state["known_peers"])
            return state
        elif hasattr(chain_or_segment, 'get_state_at'):
            # It's a Chain object
            return chain_or_segment.get_state_at(target_hash)
        return None

    def _select_witnesses(
        self,
        seed: bytes,
        chain_state: dict,
        count: int = WITNESS_COUNT,
        exclude: List[str] = None,
        min_high_trust: int = MIN_HIGH_TRUST_WITNESSES,
        max_prior_interactions: int = MAX_PRIOR_INTERACTIONS,
        interaction_with: str = None,
    ) -> List[str]:
        """SELECT_WITNESSES: Deterministically select witnesses from seed and chain state."""
        import random as _random
        exclude = exclude or []
        # Always exclude self, consumer, and provider from witness selection
        auto_exclude = {self.peer_id, self.load('consumer'), self.load('provider')}
        exclude = set(exclude) | {x for x in auto_exclude if x}
        
        # Get candidates from chain state
        known_peers = chain_state.get("known_peers", [])
        candidates = [p for p in known_peers if p not in exclude]
        
        if not candidates:
            return []
        
        # Sort deterministically
        candidates = sorted(candidates)
        
        # Filter by interaction count if available
        if interaction_with and "interaction_counts" in chain_state:
            counts = chain_state["interaction_counts"]
            candidates = [
                c for c in candidates
                if counts.get(c, 0) <= max_prior_interactions
            ]
        
        # Separate by trust level
        trust_scores = chain_state.get("trust_scores", {})
        HIGH_TRUST_THRESHOLD = 1.0
        
        high_trust = sorted([c for c in candidates if trust_scores.get(c, 0) >= HIGH_TRUST_THRESHOLD])
        low_trust = sorted([c for c in candidates if trust_scores.get(c, 0) < HIGH_TRUST_THRESHOLD])
        
        # Seeded selection
        rng = _random.Random(seed)
        
        selected = []
        
        # Select required high-trust witnesses
        if high_trust:
            ht_sample = min(min_high_trust, len(high_trust))
            selected.extend(rng.sample(high_trust, ht_sample))
        
        # Fill remaining slots from all candidates
        remaining = [c for c in candidates if c not in selected]
        needed = count - len(selected)
        if remaining and needed > 0:
            selected.extend(rng.sample(remaining, min(needed, len(remaining))))
        
        return selected

    def _verify_witness_selection(
        self,
        proposed_witnesses: List[str],
        chain_state: dict,
        session_id: Any,
        provider_nonce: bytes,
        consumer_nonce: bytes,
    ) -> bool:
        """VERIFY_WITNESS_SELECTION: Verify that proposed witnesses were correctly selected."""
        # Recompute the seed and selection
        seed = hash_data(self._to_hashable(session_id, provider_nonce, consumer_nonce))
        expected = self._select_witnesses(seed, chain_state)
        # Compare - order matters for deterministic selection
        return set(proposed_witnesses) == set(expected)

    def _validate_lock_result(
        self,
        result: dict,
        expected_session_id: str,
        expected_amount: float,
    ) -> bool:
        """VALIDATE_LOCK_RESULT: Validate a lock result matches expected values and has ACCEPTED status."""
        if not result:
            return False
        # Check session_id matches
        if result.get("session_id") != expected_session_id:
            return False
        # Check amount matches
        if result.get("amount") != expected_amount:
            return False
        # Check status is ACCEPTED (as string from serialization)
        status = result.get("status")
        if status not in ("ACCEPTED", LockStatus.ACCEPTED):
            return False
        # Check we have witness signatures (at least one)
        signatures = result.get("witness_signatures", [])
        if not signatures:
            return False
        return True

    def _validate_topup_result(
        self,
        result: dict,
        expected_session_id: str,
        expected_additional_amount: float,
    ) -> bool:
        """VALIDATE_TOPUP_RESULT: Validate a top-up result matches expected values."""
        if not result:
            return False
        # Check session_id matches
        if result.get("session_id") != expected_session_id:
            return False
        # Check additional_amount matches
        if result.get("additional_amount") != expected_additional_amount:
            return False
        # Check we have witness signatures (at least one)
        signatures = result.get("witness_signatures", [])
        if not signatures:
            return False
        return True

    def _seeded_rng(self, seed: bytes) -> Any:
        """SEEDED_RNG: Create a seeded random number generator."""
        import random as _random
        return _random.Random(seed)

    def _seeded_sample(self, rng: Any, lst: list, n: int) -> list:
        """SEEDED_SAMPLE: Deterministically sample n items from list."""
        if not lst:
            return []
        return rng.sample(lst, min(n, len(lst)))

    def _remove(self, lst: list, item: Any) -> list:
        """REMOVE: Remove item from list and return new list."""
        return [x for x in lst if x != item] if lst else []

    def _sort(self, lst: list, key_fn: str = None) -> list:
        """SORT: Sort list by key."""
        return sorted(lst) if lst else []

    def _abort(self, reason: str) -> None:
        """ABORT: Exit state machine with error."""
        raise RuntimeError(f"ABORT: {reason}")

    def _COMPUTE_CONSENSUS(self, verdicts: List[str], threshold: int) -> str:
        """Compute COMPUTE_CONSENSUS."""
        # TODO: Implement - accept_count = LENGTH (FILTER (verdicts, v = > v =...
        return None

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        # TODO: Implement - RETURN MAP (records, r = > r.{field})...
        return None

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        # TODO: Implement - RETURN LENGTH (FILTER (items, predicate))...
        return None

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        # TODO: Implement - RETURN LENGTH (FILTER (items, x = > x == item))> 0...
        return None

    def _count_positive_votes(self, votes: List[Dict[str, Any]]) -> int:
        """Compute count_positive_votes."""
        return len([v for v in votes if v.get('can_reach_vm') == True])

    def _build_cabal_votes_map(self, votes: List[Dict[str, Any]]) -> Dict[str, bool]:
        """Compute build_cabal_votes_map."""
        # TODO: Implement - result = {} FOR v IN votes: result [ v.witness ] =...
        return None

    def _check_vm_connectivity(self, vm_endpoint: str) -> bool:
        """Compute check_vm_connectivity."""
        # Native function from: omerta.native.vm_connectivity
        return check_vm_connectivity(vm_endpoint)

    def _check_consumer_connected(self, session_id: str) -> bool:
        """Compute check_consumer_connected."""
        # Native function from: omerta.native.vm_connectivity
        return check_consumer_connected(session_id)

# =============================================================================
# Witness
# =============================================================================

class WitnessState(Enum):
    """Witness states."""
    AWAITING_ALLOCATION = auto()  # Waiting for VM_ALLOCATED from provider
    VERIFYING_VM = auto()  # Checking VM connectivity
    COLLECTING_VOTES = auto()  # Collecting connectivity votes from other witnesses
    EVALUATING_CONNECTIVITY = auto()  # Deciding if VM is accessible
    MONITORING = auto()  # Session running, periodic health checks
    HANDLING_MISUSE = auto()  # Investigating misuse accusation
    VOTING_ABORT = auto()  # Voting to abort session
    COLLECTING_ABORT_VOTES = auto()  # Collecting abort votes from other witnesses
    ATTESTING = auto()  # Creating attestation after session ends
    COLLECTING_ATTESTATION_SIGS = auto()  # Multi-signing attestation
    PROPAGATING_ATTESTATION = auto()  # Sending attestation to parties
    DONE = auto()  # Attestation complete

@dataclass
class Witness(Actor):
    """Verifies VM accessibility, monitors session, creates attestation"""

    state: WitnessState = WitnessState.AWAITING_ALLOCATION
    cached_chains: Dict[str, dict] = field(default_factory=dict)

    def setup_session(self, session_id: str, consumer: str, provider: str, other_witnesses: List[str]):
        """Initialize witness with session info after escrow lock"""
        if self.state not in (WitnessState.AWAITING_ALLOCATION,):
            raise ValueError(f"Cannot setup_session in state {self.state}")

        self.store("session_id", session_id)
        self.store("consumer", consumer)
        self.store("provider", provider)
        self.store("other_witnesses", other_witnesses)
        self.transition_to(WitnessState.AWAITING_ALLOCATION)

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == WitnessState.AWAITING_ALLOCATION:
            # Check for VM_ALLOCATED
            msgs = self.get_messages(MessageType.VM_ALLOCATED)
            if msgs:
                msg = msgs[0]
                self.store("vm_allocated_msg", msg.payload)
                self.store("vm_allocated_at", msg.payload.get("allocated_at"))
                self.transition_to(WitnessState.VERIFYING_VM)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == WitnessState.VERIFYING_VM:
            # Auto transition
            # Compute: can_reach_vm = check_vm_connectivity(vm_allocated_msg.consumer_wireguard_endpoint)
            self.store("can_reach_vm", self._compute_can_reach_vm())
            # Compute: can_see_consumer_connected = check_consumer_connected(session_id)
            self.store("can_see_consumer_connected", self._compute_can_see_consumer_connected())
            self.store("witness", self.peer_id)
            # Compute: vote_data = {session_id: LOAD(session_id), witness: peer_id, can_reach_vm: LOAD(can_reach_vm), can_see_consumer_connected: LOAD(can_see_consumer_connected), timestamp: NOW()}
            self.store("vote_data", self._compute_vote_data())
            # Compute: vote_signature = SIGN(LOAD(vote_data))
            self.store("vote_signature", self._compute_vote_signature())
            # Compute: my_connectivity_vote = {...LOAD(vote_data), signature: LOAD(vote_signature)}
            self.store("my_connectivity_vote", self._compute_my_connectivity_vote())
            for recipient in self.load("other_witnesses", []):
                msg_payload = self._build_vm_connectivity_vote_payload()
                outgoing.append(Message(
                    msg_type=MessageType.VM_CONNECTIVITY_VOTE,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            msg_payload = self._build_vm_connectivity_vote_payload()
            outgoing.append(Message(
                msg_type=MessageType.VM_CONNECTIVITY_VOTE,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("provider"),
            ))
            self.store("connectivity_votes", [self.load("my_connectivity_vote")])
            self.store("votes_sent_at", self.current_time)
            self.transition_to(WitnessState.COLLECTING_VOTES)

        elif self.state == WitnessState.COLLECTING_VOTES:
            # Check for VM_CONNECTIVITY_VOTE
            msgs = self.get_messages(MessageType.VM_CONNECTIVITY_VOTE)
            if msgs:
                msg = msgs[0]
                _list = self.load("connectivity_votes") or []
                _list.append(msg.payload)
                self.store("connectivity_votes", _list)
                self.transition_to(WitnessState.COLLECTING_VOTES)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if current_time - self.load("state_entered_at", 0) > CONNECTIVITY_VOTE_TIMEOUT:
                self.transition_to(WitnessState.EVALUATING_CONNECTIVITY)

            # Auto transition with guard: LENGTH (connectivity_votes) >= LENGTH (other_witnesses) + 1
            if self._check_LENGTH_connectivity_votes_gte_LENGTH_other_witnesses_1():
                self.transition_to(WitnessState.EVALUATING_CONNECTIVITY)

        elif self.state == WitnessState.EVALUATING_CONNECTIVITY:
            # Auto transition with guard: LENGTH (connectivity_votes) > 0  and count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) >= CONNECTIVITY_THRESHOLD
            if self._check_LENGTH_connectivity_votes_gt_0_and_count_positive_votes_conn():
                self.store("connectivity_verified", True)
                self.transition_to(WitnessState.MONITORING)
            # Auto transition with guard: LENGTH (connectivity_votes) == 0  or count_positive_votes (connectivity_votes) / LENGTH (connectivity_votes) < CONNECTIVITY_THRESHOLD
            elif self._check_LENGTH_connectivity_votes_eq_0_or_count_positive_votes_conne():
                self.store("connectivity_verified", False)
                self.store("abort_reason", 'vm_unreachable')
                self.transition_to(WitnessState.VOTING_ABORT)

        elif self.state == WitnessState.MONITORING:
            # Check for VM_CANCELLED
            msgs = self.get_messages(MessageType.VM_CANCELLED)
            if msgs:
                msg = msgs[0]
                self.store("vm_cancelled_msg", msg.payload)
                self.store("actual_duration_seconds", msg.payload.get("actual_duration_seconds"))
                self.store("termination_reason", msg.payload.get("reason"))
                self.transition_to(WitnessState.ATTESTING)
                self.message_queue.remove(msg)  # Only remove processed message

            # Check for MISUSE_ACCUSATION
            msgs = self.get_messages(MessageType.MISUSE_ACCUSATION)
            if msgs:
                msg = msgs[0]
                self.store("misuse_accusation", msg.payload)
                self.transition_to(WitnessState.HANDLING_MISUSE)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == WitnessState.HANDLING_MISUSE:
            # Auto transition with guard: LOAD (misuse_accusation).evidence != ""
            if self._check_LOAD_misuse_accusation_evidence_neq():
                self.store("abort_reason", 'consumer_misuse')
                self.transition_to(WitnessState.VOTING_ABORT)
            # Auto transition with guard: LOAD (misuse_accusation).evidence == ""
            elif self._check_LOAD_misuse_accusation_evidence_eq():
                self.transition_to(WitnessState.MONITORING)

        elif self.state == WitnessState.VOTING_ABORT:
            # Auto transition
            # Compute: abort_vote_data = {session_id: LOAD(session_id), witness: peer_id, reason: LOAD(abort_reason), timestamp: NOW()}
            self.store("abort_vote_data", self._compute_abort_vote_data())
            # Compute: abort_vote_signature = SIGN(LOAD(abort_vote_data))
            self.store("abort_vote_signature", self._compute_abort_vote_signature())
            # Compute: my_abort_vote = {...LOAD(abort_vote_data), signature: LOAD(abort_vote_signature)}
            self.store("my_abort_vote", self._compute_my_abort_vote())
            for recipient in self.load("other_witnesses", []):
                msg_payload = self._build_abort_vote_payload()
                outgoing.append(Message(
                    msg_type=MessageType.ABORT_VOTE,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.store("abort_votes", [self.load("my_abort_vote")])
            self.store("abort_votes_sent_at", self.current_time)
            self.transition_to(WitnessState.COLLECTING_ABORT_VOTES)

        elif self.state == WitnessState.COLLECTING_ABORT_VOTES:
            # Check for ABORT_VOTE
            msgs = self.get_messages(MessageType.ABORT_VOTE)
            if msgs:
                msg = msgs[0]
                _list = self.load("abort_votes") or []
                _list.append(msg.payload)
                self.store("abort_votes", _list)
                self.transition_to(WitnessState.COLLECTING_ABORT_VOTES)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if current_time - self.load("state_entered_at", 0) > ABORT_VOTE_TIMEOUT:
                self.transition_to(WitnessState.MONITORING)

            # Timeout check
            if current_time - self.load("state_entered_at", 0) > ABORT_VOTE_TIMEOUT:
                self.store("session_aborted", True)
                self.store("termination_reason", self.load("abort_reason"))
                self.transition_to(WitnessState.ATTESTING)

            # Auto transition with guard: LENGTH (abort_votes) / (LENGTH (other_witnesses) + 1) >= ABORT_THRESHOLD
            if self._check_LENGTH_abort_votes_LENGTH_other_witnesses_1_gte_ABORT_THRESH():
                self.store("session_aborted", True)
                self.store("termination_reason", self.load("abort_reason"))
                self.transition_to(WitnessState.ATTESTING)

        elif self.state == WitnessState.ATTESTING:
            # Auto transition
            # Compute: attestation = {session_id: LOAD(session_id), vm_allocated_hash: HASH(LOAD(vm_allocated_msg)), vm_cancelled_hash: HASH(LOAD(vm_cancelled_msg)), connectivity_verified: LOAD(connectivity_verified), actual_duration_seconds: LOAD(actual_duration_seconds), termination_reason: LOAD(termination_reason), cabal_votes: LOAD(connectivity_votes), cabal_signatures:[], created_at: NOW()}
            self.store("attestation", self._compute_attestation())
            # Compute: my_signature = SIGN(LOAD(attestation))
            self.store("my_signature", self._compute_my_signature())
            self.store("attestation_signatures", [{self.load("witness"): self.peer_id, self.load("signature"): self.load("my_signature")}])
            for recipient in self.load("other_witnesses", []):
                msg_payload = self._build_attestation_share_payload()
                outgoing.append(Message(
                    msg_type=MessageType.ATTESTATION_SHARE,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.store("attestation_sent_at", self.current_time)
            self.transition_to(WitnessState.COLLECTING_ATTESTATION_SIGS)

        elif self.state == WitnessState.COLLECTING_ATTESTATION_SIGS:
            # Check for ATTESTATION_SHARE
            msgs = self.get_messages(MessageType.ATTESTATION_SHARE)
            if msgs:
                msg = msgs[0]
                _list = self.load("attestation_signatures") or []
                _list.append(msg.payload.get("attestation.cabal_signatures"))
                self.store("attestation_signatures", _list)
                self.transition_to(WitnessState.COLLECTING_ATTESTATION_SIGS)
                self.message_queue.remove(msg)  # Only remove processed message

            # Auto transition with guard: LENGTH (attestation_signatures) >= ATTESTATION_THRESHOLD
            if self._check_LENGTH_attestation_signatures_gte_ATTESTATION_THRESHOLD():
                self.transition_to(WitnessState.PROPAGATING_ATTESTATION)

        elif self.state == WitnessState.PROPAGATING_ATTESTATION:
            # Auto transition
            # Compute: final_attestation = {...LOAD(attestation), cabal_signatures: LOAD(attestation_signatures)}
            self.store("final_attestation", self._compute_final_attestation())
            msg_payload = self._build_attestation_result_payload()
            outgoing.append(Message(
                msg_type=MessageType.ATTESTATION_RESULT,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("consumer"),
            ))
            msg_payload = self._build_attestation_result_payload()
            outgoing.append(Message(
                msg_type=MessageType.ATTESTATION_RESULT,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("provider"),
            ))
            self.chain.append(
                BlockType.ATTESTATION,
                self._build_attestation_payload(),
                current_time,
            )
            self.transition_to(WitnessState.DONE)

        elif self.state == WitnessState.DONE:
            # Attestation complete
            pass

        return outgoing

    def _build_vm_connectivity_vote_payload(self) -> Dict[str, Any]:
        """Build payload for VM_CONNECTIVITY_VOTE message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "witness": self._serialize_value(self.load("witness")),
            "can_reach_vm": self._serialize_value(self.load("can_reach_vm")),
            "can_see_consumer_connected": self._serialize_value(self.load("can_see_consumer_connected")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_abort_vote_payload(self) -> Dict[str, Any]:
        """Build payload for ABORT_VOTE message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "witness": self._serialize_value(self.load("witness")),
            "reason": self._serialize_value(self.load("reason")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_attestation_result_payload(self) -> Dict[str, Any]:
        """Build payload for ATTESTATION_RESULT message."""
        payload = {
            "attestation": self._serialize_value(self.load("attestation")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_attestation_share_payload(self) -> Dict[str, Any]:
        """Build payload for ATTESTATION_SHARE message."""
        payload = {
            "attestation": self._serialize_value(self.load("attestation")),
            "timestamp": self.current_time,
        }
        return payload

    def _check_message_payload_witness_neq_peer_id(self) -> bool:
        # Schema: message.payload.witness != peer_id...
        return self.load("message").get("payload").get("witness")!= self.peer_id

    def _check_LENGTH_connectivity_votes_gte_LENGTH_other_witnesses_1(self) -> bool:
        # Schema: LENGTH (connectivity_votes) >= LENGTH (other_witnesses) + 1...
        return len (self.load("connectivity_votes")) >= len (self.load("other_witnesses")) + 1

    def _check_LENGTH_connectivity_votes_gt_0_and_count_positive_votes_conn(self) -> bool:
        # Schema: LENGTH (connectivity_votes) > 0 and count_positive_votes (co...
        return len (self.load("connectivity_votes")) > 0 and self._count_positive_votes (self.load("connectivity_votes")) / len (self.load("connectivity_votes")) >= CONNECTIVITY_THRESHOLD

    def _check_LENGTH_connectivity_votes_eq_0_or_count_positive_votes_conne(self) -> bool:
        # Schema: LENGTH (connectivity_votes) == 0 or count_positive_votes (co...
        return len (self.load("connectivity_votes")) == 0 or self._count_positive_votes (self.load("connectivity_votes")) / len (self.load("connectivity_votes")) < CONNECTIVITY_THRESHOLD

    def _check_LOAD_misuse_accusation_evidence_neq(self) -> bool:
        # Schema: LOAD (misuse_accusation).evidence != ""...
        return self.load("misuse_accusation").self.load("evidence") != ""

    def _check_LOAD_misuse_accusation_evidence_eq(self) -> bool:
        # Schema: LOAD (misuse_accusation).evidence == ""...
        return self.load("misuse_accusation").self.load("evidence") == ""

    def _check_LENGTH_abort_votes_LENGTH_other_witnesses_1_gte_ABORT_THRESH(self) -> bool:
        # Schema: LENGTH (abort_votes) / (LENGTH (other_witnesses) + 1) >= ABO...
        return len (self.load("abort_votes")) / (len (self.load("other_witnesses")) + 1) >= ABORT_THRESHOLD

    def _check_LENGTH_abort_votes_LENGTH_other_witnesses_1_lt_ABORT_THRESHO(self) -> bool:
        # Schema: LENGTH (abort_votes) / (LENGTH (other_witnesses) + 1) < ABOR...
        return len (self.load("abort_votes")) / (len (self.load("other_witnesses")) + 1) < ABORT_THRESHOLD

    def _check_LENGTH_attestation_signatures_gte_ATTESTATION_THRESHOLD(self) -> bool:
        # Schema: LENGTH (attestation_signatures) >= ATTESTATION_THRESHOLD...
        return len (self.load("attestation_signatures")) >= ATTESTATION_THRESHOLD

    def _compute_can_reach_vm(self) -> Any:
        """Compute can_reach_vm."""
        # Schema: check_vm_connectivity(vm_allocated_msg.consumer_wireguard_en...
        return self._check_vm_connectivity(self.load("vm_allocated_msg").get("consumer_wireguard_endpoint"))

    def _compute_can_see_consumer_connected(self) -> Any:
        """Compute can_see_consumer_connected."""
        # Schema: check_consumer_connected(session_id)...
        return self._check_consumer_connected(self.load("session_id"))

    def _compute_vote_data(self) -> Any:
        """Compute vote_data."""
        # Schema: {session_id: LOAD(session_id), witness: peer_id, can_reach_v...
        return {"session_id": self.load("session_id"), "witness": self.peer_id, "can_reach_vm": self.load("can_reach_vm"), "can_see_consumer_connected": self.load("can_see_consumer_connected"), "timestamp": self.current_time}

    def _compute_vote_signature(self) -> Any:
        """Compute vote_signature."""
        # Schema: SIGN(LOAD(vote_data))...
        return sign(self.chain.private_key, hash_data(self.load("vote_data")))

    def _compute_my_connectivity_vote(self) -> Any:
        """Compute my_connectivity_vote."""
        # Schema: {...LOAD(vote_data), signature: LOAD(vote_signature)}...
        return {**self.load("vote_data"), "signature": self.load("vote_signature")}

    def _compute_abort_vote_data(self) -> Any:
        """Compute abort_vote_data."""
        # Schema: {session_id: LOAD(session_id), witness: peer_id, reason: LOA...
        return {"session_id": self.load("session_id"), "witness": self.peer_id, "reason": self.load("abort_reason"), "timestamp": self.current_time}

    def _compute_abort_vote_signature(self) -> Any:
        """Compute abort_vote_signature."""
        # Schema: SIGN(LOAD(abort_vote_data))...
        return sign(self.chain.private_key, hash_data(self.load("abort_vote_data")))

    def _compute_my_abort_vote(self) -> Any:
        """Compute my_abort_vote."""
        # Schema: {...LOAD(abort_vote_data), signature: LOAD(abort_vote_signat...
        return {**self.load("abort_vote_data"), "signature": self.load("abort_vote_signature")}

    def _compute_attestation(self) -> Any:
        """Compute attestation."""
        # Schema: {session_id: LOAD(session_id), vm_allocated_hash: HASH(LOAD(...
        return {"session_id": self.load("session_id"), "vm_allocated_hash": hash_data(self._to_hashable(self.load("vm_allocated_msg"))), "vm_cancelled_hash": hash_data(self._to_hashable(self.load("vm_cancelled_msg"))), "connectivity_verified": self.load("connectivity_verified"), "actual_duration_seconds": self.load("actual_duration_seconds"), "termination_reason": self.load("termination_reason"), "cabal_votes": self.load("connectivity_votes"), "cabal_signatures": [], "created_at": self.current_time}

    def _compute_my_signature(self) -> Any:
        """Compute my_signature."""
        # Schema: SIGN(LOAD(attestation))...
        return sign(self.chain.private_key, hash_data(self.load("attestation")))

    def _compute_final_attestation(self) -> Any:
        """Compute final_attestation."""
        # Schema: {...LOAD(attestation), cabal_signatures: LOAD(attestation_si...
        return {**self.load("attestation"), "cabal_signatures": self.load("attestation_signatures")}

    def _build_attestation_payload(self) -> Dict[str, Any]:
        """Build payload for ATTESTATION chain block."""
        return {
            "session_id": self.load("session_id"),
            "connectivity_verified": self.load("connectivity_verified"),
            "actual_duration_seconds": self.load("actual_duration_seconds"),
            "termination_reason": self.load("termination_reason"),
            "witnesses": self.load("witnesses"),
            "timestamp": self.current_time,
        }

    def _verify_chain_segment(self, segment: List[dict]) -> bool:
        """VERIFY_CHAIN_SEGMENT: Verify a chain segment is valid."""
        if not segment:
            return False
        # Verify hash chain integrity
        for i in range(1, len(segment)):
            if segment[i].get("previous_hash") != segment[i-1].get("block_hash"):
                return False
            # Verify sequences are consecutive
            if segment[i].get("sequence") != segment[i-1].get("sequence") + 1:
                return False
        return True

    def _chain_contains_hash(self, chain_or_segment: Any, target_hash: str) -> bool:
        """CHAIN_CONTAINS_HASH: Check if chain/segment contains a hash."""
        if isinstance(chain_or_segment, list):
            # It's a segment (list of block dicts)
            return any(b.get('block_hash') == target_hash for b in chain_or_segment)
        elif hasattr(chain_or_segment, 'contains_hash'):
            # It's a Chain object
            return chain_or_segment.contains_hash(target_hash)
        return False

    def _chain_state_at(self, chain_or_segment: Any, target_hash: str) -> Optional[Dict[str, Any]]:
        """CHAIN_STATE_AT: Extract chain state at a specific block hash."""
        if isinstance(chain_or_segment, list):
            # It's a segment - find the block and build state
            target_idx = None
            for i, block in enumerate(chain_or_segment):
                if block.get('block_hash') == target_hash:
                    target_idx = i
                    break
            if target_idx is None:
                return None
            # Build state from blocks up to target
            state = {
                "known_peers": set(),
                "peer_hashes": {},
                "balance_locks": [],
                "block_hash": target_hash,
                "sequence": target_idx,
            }
            for block in chain_or_segment[:target_idx + 1]:
                if block.get('block_type') == 'peer_hash':
                    peer = block.get('payload', {}).get('peer')
                    if peer:
                        state["known_peers"].add(peer)
                        state["peer_hashes"][peer] = block.get("payload", {}).get("hash")
                elif block.get('block_type') == 'balance_lock':
                    state["balance_locks"].append(block.get("payload", {}))
            state["known_peers"] = list(state["known_peers"])
            return state
        elif hasattr(chain_or_segment, 'get_state_at'):
            # It's a Chain object
            return chain_or_segment.get_state_at(target_hash)
        return None

    def _select_witnesses(
        self,
        seed: bytes,
        chain_state: dict,
        count: int = WITNESS_COUNT,
        exclude: List[str] = None,
        min_high_trust: int = MIN_HIGH_TRUST_WITNESSES,
        max_prior_interactions: int = MAX_PRIOR_INTERACTIONS,
        interaction_with: str = None,
    ) -> List[str]:
        """SELECT_WITNESSES: Deterministically select witnesses from seed and chain state."""
        import random as _random
        exclude = exclude or []
        # Always exclude self, consumer, and provider from witness selection
        auto_exclude = {self.peer_id, self.load('consumer'), self.load('provider')}
        exclude = set(exclude) | {x for x in auto_exclude if x}
        
        # Get candidates from chain state
        known_peers = chain_state.get("known_peers", [])
        candidates = [p for p in known_peers if p not in exclude]
        
        if not candidates:
            return []
        
        # Sort deterministically
        candidates = sorted(candidates)
        
        # Filter by interaction count if available
        if interaction_with and "interaction_counts" in chain_state:
            counts = chain_state["interaction_counts"]
            candidates = [
                c for c in candidates
                if counts.get(c, 0) <= max_prior_interactions
            ]
        
        # Separate by trust level
        trust_scores = chain_state.get("trust_scores", {})
        HIGH_TRUST_THRESHOLD = 1.0
        
        high_trust = sorted([c for c in candidates if trust_scores.get(c, 0) >= HIGH_TRUST_THRESHOLD])
        low_trust = sorted([c for c in candidates if trust_scores.get(c, 0) < HIGH_TRUST_THRESHOLD])
        
        # Seeded selection
        rng = _random.Random(seed)
        
        selected = []
        
        # Select required high-trust witnesses
        if high_trust:
            ht_sample = min(min_high_trust, len(high_trust))
            selected.extend(rng.sample(high_trust, ht_sample))
        
        # Fill remaining slots from all candidates
        remaining = [c for c in candidates if c not in selected]
        needed = count - len(selected)
        if remaining and needed > 0:
            selected.extend(rng.sample(remaining, min(needed, len(remaining))))
        
        return selected

    def _verify_witness_selection(
        self,
        proposed_witnesses: List[str],
        chain_state: dict,
        session_id: Any,
        provider_nonce: bytes,
        consumer_nonce: bytes,
    ) -> bool:
        """VERIFY_WITNESS_SELECTION: Verify that proposed witnesses were correctly selected."""
        # Recompute the seed and selection
        seed = hash_data(self._to_hashable(session_id, provider_nonce, consumer_nonce))
        expected = self._select_witnesses(seed, chain_state)
        # Compare - order matters for deterministic selection
        return set(proposed_witnesses) == set(expected)

    def _validate_lock_result(
        self,
        result: dict,
        expected_session_id: str,
        expected_amount: float,
    ) -> bool:
        """VALIDATE_LOCK_RESULT: Validate a lock result matches expected values and has ACCEPTED status."""
        if not result:
            return False
        # Check session_id matches
        if result.get("session_id") != expected_session_id:
            return False
        # Check amount matches
        if result.get("amount") != expected_amount:
            return False
        # Check status is ACCEPTED (as string from serialization)
        status = result.get("status")
        if status not in ("ACCEPTED", LockStatus.ACCEPTED):
            return False
        # Check we have witness signatures (at least one)
        signatures = result.get("witness_signatures", [])
        if not signatures:
            return False
        return True

    def _validate_topup_result(
        self,
        result: dict,
        expected_session_id: str,
        expected_additional_amount: float,
    ) -> bool:
        """VALIDATE_TOPUP_RESULT: Validate a top-up result matches expected values."""
        if not result:
            return False
        # Check session_id matches
        if result.get("session_id") != expected_session_id:
            return False
        # Check additional_amount matches
        if result.get("additional_amount") != expected_additional_amount:
            return False
        # Check we have witness signatures (at least one)
        signatures = result.get("witness_signatures", [])
        if not signatures:
            return False
        return True

    def _seeded_rng(self, seed: bytes) -> Any:
        """SEEDED_RNG: Create a seeded random number generator."""
        import random as _random
        return _random.Random(seed)

    def _seeded_sample(self, rng: Any, lst: list, n: int) -> list:
        """SEEDED_SAMPLE: Deterministically sample n items from list."""
        if not lst:
            return []
        return rng.sample(lst, min(n, len(lst)))

    def _remove(self, lst: list, item: Any) -> list:
        """REMOVE: Remove item from list and return new list."""
        return [x for x in lst if x != item] if lst else []

    def _sort(self, lst: list, key_fn: str = None) -> list:
        """SORT: Sort list by key."""
        return sorted(lst) if lst else []

    def _abort(self, reason: str) -> None:
        """ABORT: Exit state machine with error."""
        raise RuntimeError(f"ABORT: {reason}")

    def _compute_consensus(self, preliminaries: list) -> str:
        """COMPUTE_CONSENSUS: Determine consensus from preliminary verdicts."""
        # Start with witness's own verdict
        my_verdict = self.load('verdict')
        accept_count = 1 if my_verdict in ('ACCEPT', 'accept', WitnessVerdict.ACCEPT) else 0
        reject_count = 1 - accept_count
        # Count verdicts from other witnesses
        for p in (preliminaries or []):
            verdict = p.get('verdict') if isinstance(p, dict) else getattr(p, 'verdict', None)
            if verdict in ('ACCEPT', WitnessVerdict.ACCEPT):
                accept_count += 1
            else:
                reject_count += 1
        # Need threshold for acceptance
        if accept_count >= WITNESS_THRESHOLD:
            return "ACCEPT"
        return "REJECT"

    def _build_lock_result(self) -> Dict[str, Any]:
        """BUILD_LOCK_RESULT: Build the final lock result structure."""
        consensus = self.load('consensus_direction')
        # Use enum for type checking but store name for JSON serialization
        status_enum = LockStatus.ACCEPTED if consensus == 'ACCEPT' else LockStatus.REJECTED
        # Extract signatures from collected votes
        votes = self.load('votes') or []
        signatures = [v.get('signature') for v in votes if v.get('signature')]
        return {
            "session_id": self.load("session_id"),
            "consumer": self.load("consumer"),
            "provider": self.load("provider"),
            "amount": self.load("amount"),
            "status": status_enum.name,  # Use string for JSON serialization
            "observed_balance": self.load("observed_balance"),
            "witnesses": self.load("witnesses"),
            "witness_signatures": signatures,
            "timestamp": self.current_time,
        }

    def _build_topup_result(self) -> Dict[str, Any]:
        """BUILD_TOPUP_RESULT: Build the top-up result structure."""
        topup_intent = self.load('topup_intent') or {}
        # Extract signatures from collected votes
        votes = self.load('topup_votes') or []
        signatures = [v.get('signature') for v in votes if v.get('signature')]
        # Add our own signature
        my_signature = sign(self.chain.private_key, hash_data({'verdict': self.load('topup_verdict'), 'session_id': self.load('session_id')}))
        signatures.append(my_signature)
        return {
            "session_id": self.load("session_id"),
            "consumer": self.load("consumer"),
            "provider": self.load("provider"),
            "previous_total": self.load("total_escrowed"),
            "additional_amount": topup_intent.get("additional_amount"),
            "new_total": self.load("total_escrowed") + topup_intent.get("additional_amount", 0),
            "observed_balance": self.load("topup_observed_balance"),
            "witnesses": self.load("witnesses"),
            "witness_signatures": signatures,
            "timestamp": self.current_time,
        }

    def _COMPUTE_CONSENSUS(self, verdicts: List[str], threshold: int) -> str:
        """Compute COMPUTE_CONSENSUS."""
        # TODO: Implement - accept_count = LENGTH (FILTER (verdicts, v = > v =...
        return None

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        # TODO: Implement - RETURN MAP (records, r = > r.{field})...
        return None

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        # TODO: Implement - RETURN LENGTH (FILTER (items, predicate))...
        return None

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        # TODO: Implement - RETURN LENGTH (FILTER (items, x = > x == item))> 0...
        return None

    def _count_positive_votes(self, votes: List[Dict[str, Any]]) -> int:
        """Compute count_positive_votes."""
        return len([v for v in votes if v.get('can_reach_vm') == True])

    def _build_cabal_votes_map(self, votes: List[Dict[str, Any]]) -> Dict[str, bool]:
        """Compute build_cabal_votes_map."""
        # TODO: Implement - result = {} FOR v IN votes: result [ v.witness ] =...
        return None

    def _check_vm_connectivity(self, vm_endpoint: str) -> bool:
        """Compute check_vm_connectivity."""
        # Native function from: omerta.native.vm_connectivity
        return check_vm_connectivity(vm_endpoint)

    def _check_consumer_connected(self, session_id: str) -> bool:
        """Compute check_consumer_connected."""
        # Native function from: omerta.native.vm_connectivity
        return check_consumer_connected(session_id)

# =============================================================================
# Consumer
# =============================================================================

class ConsumerState(Enum):
    """Consumer states."""
    WAITING_FOR_VM = auto()  # Waiting for VM to be ready
    CONNECTING = auto()  # Connecting to VM via wireguard
    CONNECTED = auto()  # Using the VM
    REQUESTING_CANCEL = auto()  # Requesting session end
    SESSION_ENDED = auto()  # Session terminated

@dataclass
class Consumer(Actor):
    """Connects to VM, uses service"""

    state: ConsumerState = ConsumerState.WAITING_FOR_VM

    @property
    def is_locked(self) -> bool:
        """Check if consumer is in LOCKED state."""
        return self.state == ConsumerState.LOCKED

    @property
    def is_failed(self) -> bool:
        """Check if consumer is in FAILED state."""
        return self.state == ConsumerState.FAILED

    @property
    def total_escrowed(self) -> float:
        """Get total escrowed amount."""
        return self.load("total_escrowed", 0.0)

    def setup_session(self, session_id: str, provider: str):
        """Initialize consumer with session info"""
        if self.state not in (ConsumerState.WAITING_FOR_VM,):
            raise ValueError(f"Cannot setup_session in state {self.state}")

        self.store("session_id", session_id)
        self.store("provider", provider)
        self.transition_to(ConsumerState.WAITING_FOR_VM)

    def request_cancel(self):
        """Request to end session early"""
        if self.state not in (ConsumerState.CONNECTED,):
            raise ValueError(f"Cannot request_cancel in state {self.state}")

        self.transition_to(ConsumerState.REQUESTING_CANCEL)

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ConsumerState.WAITING_FOR_VM:
            # Check for VM_READY
            msgs = self.get_messages(MessageType.VM_READY)
            if msgs:
                msg = msgs[0]
                self.store("vm_info", msg.payload.get("vm_info"))
                self.transition_to(ConsumerState.CONNECTING)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == ConsumerState.CONNECTING:
            # Auto transition
            self.store("connected_at", self.current_time)
            self.transition_to(ConsumerState.CONNECTED)

        elif self.state == ConsumerState.CONNECTED:
            # Check for SESSION_TERMINATED
            msgs = self.get_messages(MessageType.SESSION_TERMINATED)
            if msgs:
                msg = msgs[0]
                self.store("termination_reason", msg.payload.get("reason"))
                self.transition_to(ConsumerState.SESSION_ENDED)
                self.message_queue.remove(msg)  # Only remove processed message

            # Check for ATTESTATION_RESULT
            msgs = self.get_messages(MessageType.ATTESTATION_RESULT)
            if msgs:
                msg = msgs[0]
                self.store("attestation", msg.payload.get("attestation"))
                self.transition_to(ConsumerState.CONNECTED)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == ConsumerState.REQUESTING_CANCEL:
            # Auto transition
            msg_payload = self._build_cancel_request_payload()
            outgoing.append(Message(
                msg_type=MessageType.CANCEL_REQUEST,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("provider"),
            ))
            self.transition_to(ConsumerState.CONNECTED)

        elif self.state == ConsumerState.SESSION_ENDED:
            # Check for ATTESTATION_RESULT
            msgs = self.get_messages(MessageType.ATTESTATION_RESULT)
            if msgs:
                msg = msgs[0]
                self.store("attestation", msg.payload.get("attestation"))
                self.transition_to(ConsumerState.SESSION_ENDED)
                self.message_queue.remove(msg)  # Only remove processed message


        return outgoing

    def _build_cancel_request_payload(self) -> Dict[str, Any]:
        """Build payload for CANCEL_REQUEST message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "consumer": self._serialize_value(self.load("consumer")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _verify_chain_segment(self, segment: List[dict]) -> bool:
        """VERIFY_CHAIN_SEGMENT: Verify a chain segment is valid."""
        if not segment:
            return False
        # Verify hash chain integrity
        for i in range(1, len(segment)):
            if segment[i].get("previous_hash") != segment[i-1].get("block_hash"):
                return False
            # Verify sequences are consecutive
            if segment[i].get("sequence") != segment[i-1].get("sequence") + 1:
                return False
        return True

    def _chain_contains_hash(self, chain_or_segment: Any, target_hash: str) -> bool:
        """CHAIN_CONTAINS_HASH: Check if chain/segment contains a hash."""
        if isinstance(chain_or_segment, list):
            # It's a segment (list of block dicts)
            return any(b.get('block_hash') == target_hash for b in chain_or_segment)
        elif hasattr(chain_or_segment, 'contains_hash'):
            # It's a Chain object
            return chain_or_segment.contains_hash(target_hash)
        return False

    def _chain_state_at(self, chain_or_segment: Any, target_hash: str) -> Optional[Dict[str, Any]]:
        """CHAIN_STATE_AT: Extract chain state at a specific block hash."""
        if isinstance(chain_or_segment, list):
            # It's a segment - find the block and build state
            target_idx = None
            for i, block in enumerate(chain_or_segment):
                if block.get('block_hash') == target_hash:
                    target_idx = i
                    break
            if target_idx is None:
                return None
            # Build state from blocks up to target
            state = {
                "known_peers": set(),
                "peer_hashes": {},
                "balance_locks": [],
                "block_hash": target_hash,
                "sequence": target_idx,
            }
            for block in chain_or_segment[:target_idx + 1]:
                if block.get('block_type') == 'peer_hash':
                    peer = block.get('payload', {}).get('peer')
                    if peer:
                        state["known_peers"].add(peer)
                        state["peer_hashes"][peer] = block.get("payload", {}).get("hash")
                elif block.get('block_type') == 'balance_lock':
                    state["balance_locks"].append(block.get("payload", {}))
            state["known_peers"] = list(state["known_peers"])
            return state
        elif hasattr(chain_or_segment, 'get_state_at'):
            # It's a Chain object
            return chain_or_segment.get_state_at(target_hash)
        return None

    def _select_witnesses(
        self,
        seed: bytes,
        chain_state: dict,
        count: int = WITNESS_COUNT,
        exclude: List[str] = None,
        min_high_trust: int = MIN_HIGH_TRUST_WITNESSES,
        max_prior_interactions: int = MAX_PRIOR_INTERACTIONS,
        interaction_with: str = None,
    ) -> List[str]:
        """SELECT_WITNESSES: Deterministically select witnesses from seed and chain state."""
        import random as _random
        exclude = exclude or []
        # Always exclude self, consumer, and provider from witness selection
        auto_exclude = {self.peer_id, self.load('consumer'), self.load('provider')}
        exclude = set(exclude) | {x for x in auto_exclude if x}
        
        # Get candidates from chain state
        known_peers = chain_state.get("known_peers", [])
        candidates = [p for p in known_peers if p not in exclude]
        
        if not candidates:
            return []
        
        # Sort deterministically
        candidates = sorted(candidates)
        
        # Filter by interaction count if available
        if interaction_with and "interaction_counts" in chain_state:
            counts = chain_state["interaction_counts"]
            candidates = [
                c for c in candidates
                if counts.get(c, 0) <= max_prior_interactions
            ]
        
        # Separate by trust level
        trust_scores = chain_state.get("trust_scores", {})
        HIGH_TRUST_THRESHOLD = 1.0
        
        high_trust = sorted([c for c in candidates if trust_scores.get(c, 0) >= HIGH_TRUST_THRESHOLD])
        low_trust = sorted([c for c in candidates if trust_scores.get(c, 0) < HIGH_TRUST_THRESHOLD])
        
        # Seeded selection
        rng = _random.Random(seed)
        
        selected = []
        
        # Select required high-trust witnesses
        if high_trust:
            ht_sample = min(min_high_trust, len(high_trust))
            selected.extend(rng.sample(high_trust, ht_sample))
        
        # Fill remaining slots from all candidates
        remaining = [c for c in candidates if c not in selected]
        needed = count - len(selected)
        if remaining and needed > 0:
            selected.extend(rng.sample(remaining, min(needed, len(remaining))))
        
        return selected

    def _verify_witness_selection(
        self,
        proposed_witnesses: List[str],
        chain_state: dict,
        session_id: Any,
        provider_nonce: bytes,
        consumer_nonce: bytes,
    ) -> bool:
        """VERIFY_WITNESS_SELECTION: Verify that proposed witnesses were correctly selected."""
        # Recompute the seed and selection
        seed = hash_data(self._to_hashable(session_id, provider_nonce, consumer_nonce))
        expected = self._select_witnesses(seed, chain_state)
        # Compare - order matters for deterministic selection
        return set(proposed_witnesses) == set(expected)

    def _validate_lock_result(
        self,
        result: dict,
        expected_session_id: str,
        expected_amount: float,
    ) -> bool:
        """VALIDATE_LOCK_RESULT: Validate a lock result matches expected values and has ACCEPTED status."""
        if not result:
            return False
        # Check session_id matches
        if result.get("session_id") != expected_session_id:
            return False
        # Check amount matches
        if result.get("amount") != expected_amount:
            return False
        # Check status is ACCEPTED (as string from serialization)
        status = result.get("status")
        if status not in ("ACCEPTED", LockStatus.ACCEPTED):
            return False
        # Check we have witness signatures (at least one)
        signatures = result.get("witness_signatures", [])
        if not signatures:
            return False
        return True

    def _validate_topup_result(
        self,
        result: dict,
        expected_session_id: str,
        expected_additional_amount: float,
    ) -> bool:
        """VALIDATE_TOPUP_RESULT: Validate a top-up result matches expected values."""
        if not result:
            return False
        # Check session_id matches
        if result.get("session_id") != expected_session_id:
            return False
        # Check additional_amount matches
        if result.get("additional_amount") != expected_additional_amount:
            return False
        # Check we have witness signatures (at least one)
        signatures = result.get("witness_signatures", [])
        if not signatures:
            return False
        return True

    def _seeded_rng(self, seed: bytes) -> Any:
        """SEEDED_RNG: Create a seeded random number generator."""
        import random as _random
        return _random.Random(seed)

    def _seeded_sample(self, rng: Any, lst: list, n: int) -> list:
        """SEEDED_SAMPLE: Deterministically sample n items from list."""
        if not lst:
            return []
        return rng.sample(lst, min(n, len(lst)))

    def _remove(self, lst: list, item: Any) -> list:
        """REMOVE: Remove item from list and return new list."""
        return [x for x in lst if x != item] if lst else []

    def _sort(self, lst: list, key_fn: str = None) -> list:
        """SORT: Sort list by key."""
        return sorted(lst) if lst else []

    def _abort(self, reason: str) -> None:
        """ABORT: Exit state machine with error."""
        raise RuntimeError(f"ABORT: {reason}")

    def _COMPUTE_CONSENSUS(self, verdicts: List[str], threshold: int) -> str:
        """Compute COMPUTE_CONSENSUS."""
        # TODO: Implement - accept_count = LENGTH (FILTER (verdicts, v = > v =...
        return None

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        # TODO: Implement - RETURN MAP (records, r = > r.{field})...
        return None

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        # TODO: Implement - RETURN LENGTH (FILTER (items, predicate))...
        return None

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        # TODO: Implement - RETURN LENGTH (FILTER (items, x = > x == item))> 0...
        return None

    def _count_positive_votes(self, votes: List[Dict[str, Any]]) -> int:
        """Compute count_positive_votes."""
        return len([v for v in votes if v.get('can_reach_vm') == True])

    def _build_cabal_votes_map(self, votes: List[Dict[str, Any]]) -> Dict[str, bool]:
        """Compute build_cabal_votes_map."""
        # TODO: Implement - result = {} FOR v IN votes: result [ v.witness ] =...
        return None

    def _check_vm_connectivity(self, vm_endpoint: str) -> bool:
        """Compute check_vm_connectivity."""
        # Native function from: omerta.native.vm_connectivity
        return check_vm_connectivity(vm_endpoint)

    def _check_consumer_connected(self, session_id: str) -> bool:
        """Compute check_consumer_connected."""
        # Native function from: omerta.native.vm_connectivity
        return check_consumer_connected(session_id)
