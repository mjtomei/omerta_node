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
        """Convert arguments to a hashable dict, recursively handling bytes."""
        def convert(val):
            if isinstance(val, bytes):
                return val.hex()
            if isinstance(val, (list, tuple)):
                return [convert(v) for v in val]
            if isinstance(val, dict):
                return {k: convert(v) for k, v in val.items()}
            if isinstance(val, Enum):
                return val.name
            return val
        result = {}
        for i, arg in enumerate(args):
            result[f'_{i}'] = convert(arg)
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

    def in_state(self, state_name: str) -> bool:
        """Check if actor is in a named state."""
        return self.state.name == state_name

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
        self.store("termination_reason", "reason")
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
            if self.current_time - self.load('state_entered_at', 0) > VM_ALLOCATION_TIMEOUT:
                self.store("termination_reason", TerminationReason.ALLOCATION_FAILED)
                self.transition_to(ProviderState.SESSION_ABORTED)


        elif self.state == ProviderState.NOTIFYING_CABAL:
            # Auto transition
            # Compute: vm_allocated_msg = StructLiteralExpr(fields={'session_id': FunctionCallExpr(name='LOAD', args=[Identifier(name='session_id', line=0, column=0)], line=0, column=0), 'provider': Identifier(name='peer_id', line=0, column=0), 'consumer': FunctionCallExpr(name='LOAD', args=[Identifier(name='consumer', line=0, column=0)], line=0, column=0), 'vm_info': FunctionCallExpr(name='LOAD', args=[Identifier(name='vm_info', line=0, column=0)], line=0, column=0), 'allocated_at': FunctionCallExpr(name='LOAD', args=[Identifier(name='vm_allocated_at', line=0, column=0)], line=0, column=0), 'lock_result_hash': FunctionCallExpr(name='HASH', args=[FunctionCallExpr(name='LOAD', args=[Identifier(name='lock_result', line=0, column=0)], line=0, column=0)], line=0, column=0), 'timestamp': FunctionCallExpr(name='NOW', args=[], line=0, column=0)}, spread=None, line=0, column=0)
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
                _msg = msgs[0]
                _list = self.load("connectivity_votes") or []
                _list.append(_msg.payload)
                self.store("connectivity_votes", _list)
                self.transition_to(ProviderState.WAITING_FOR_VERIFICATION)
                self.message_queue.remove(_msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONNECTIVITY_CHECK_TIMEOUT:
                self.store("verification_passed", True)
                self.transition_to(ProviderState.VM_RUNNING)

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONNECTIVITY_CHECK_TIMEOUT:
                self.store("verification_passed", False)
                self.store("termination_reason", TerminationReason.CONNECTIVITY_FAILED)
                self.transition_to(ProviderState.SENDING_CANCELLATION)

            # Auto transition with guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='witnesses', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)
            if self._check_LENGTH_connectivity_votes_gte_LENGTH_witnesses_and_count_pos():
                self.store("verification_passed", True)
                self.transition_to(ProviderState.VM_RUNNING)
            # Auto transition with guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='witnesses', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.LT: 7>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)
            elif self._check_LENGTH_connectivity_votes_gte_LENGTH_witnesses_and_count_pos():
                self.store("verification_passed", False)
                self.store("termination_reason", TerminationReason.CONNECTIVITY_FAILED)
                self.transition_to(ProviderState.SENDING_CANCELLATION)

        elif self.state == ProviderState.VM_RUNNING:
            # Check for CANCEL_REQUEST
            msgs = self.get_messages(MessageType.CANCEL_REQUEST)
            if msgs:
                _msg = msgs[0]
                self.store("termination_reason", TerminationReason.CONSUMER_REQUEST)
                self.store("cancelled_at", self.current_time)
                self.transition_to(ProviderState.HANDLING_CANCEL)
                self.message_queue.remove(_msg)  # Only remove processed message


        elif self.state == ProviderState.HANDLING_CANCEL:
            # Auto transition
            self.transition_to(ProviderState.SENDING_CANCELLATION)

        elif self.state == ProviderState.SENDING_CANCELLATION:
            # Auto transition
            # Compute: vm_cancelled_msg = StructLiteralExpr(fields={'session_id': FunctionCallExpr(name='LOAD', args=[Identifier(name='session_id', line=0, column=0)], line=0, column=0), 'provider': Identifier(name='peer_id', line=0, column=0), 'cancelled_at': FunctionCallExpr(name='LOAD', args=[Identifier(name='cancelled_at', line=0, column=0)], line=0, column=0), 'reason': FunctionCallExpr(name='LOAD', args=[Identifier(name='termination_reason', line=0, column=0)], line=0, column=0), 'actual_duration_seconds': BinaryExpr(left=FunctionCallExpr(name='LOAD', args=[Identifier(name='cancelled_at', line=0, column=0)], line=0, column=0), op=<BinaryOperator.SUB: 2>, right=FunctionCallExpr(name='LOAD', args=[Identifier(name='vm_allocated_at', line=0, column=0)], line=0, column=0), line=0, column=0), 'timestamp': FunctionCallExpr(name='NOW', args=[], line=0, column=0)}, spread=None, line=0, column=0)
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
                _msg = msgs[0]
                self.store("attestation", _msg.payload.get("attestation"))
                self.transition_to(ProviderState.SESSION_COMPLETE)
                self.message_queue.remove(_msg)  # Only remove processed message


        elif self.state == ProviderState.SESSION_COMPLETE:
            # Attestation received, ready for settlement
            pass

        elif self.state == ProviderState.SESSION_ABORTED:
            # Session was aborted before completion
            pass

        return outgoing

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

    def _build_session_terminated_payload(self) -> Dict[str, Any]:
        """Build payload for SESSION_TERMINATED message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "reason": self._serialize_value(self.load("reason")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_vm_ready_payload(self) -> Dict[str, Any]:
        """Build payload for VM_READY message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "vm_info": self._serialize_value(self.load("vm_info")),
            "timestamp": self.current_time,
        }
        return payload

    def _check_LENGTH_connectivity_votes_gte_LENGTH_witnesses_and_count_pos(self) -> bool:
        # Schema: ((LENGTH(connectivity_votes) >= LENGTH(witnesses)) and ((cou...
        return ((len(self.load("connectivity_votes")) >= len(self.load("witnesses"))) and ((self._count_positive_votes(self.load("connectivity_votes")) / len(self.load("connectivity_votes"))) >= CONNECTIVITY_THRESHOLD))

    def _check_LENGTH_connectivity_votes_gt_0_and_count_positive_votes_conn(self) -> bool:
        # Schema: ((LENGTH(connectivity_votes) > 0) and ((count_positive_votes...
        return ((len(self.load("connectivity_votes")) > 0) and ((self._count_positive_votes(self.load("connectivity_votes")) / len(self.load("connectivity_votes"))) >= CONNECTIVITY_THRESHOLD))

    def _check_LENGTH_connectivity_votes_eq_0_or_count_positive_votes_conne(self) -> bool:
        # Schema: ((LENGTH(connectivity_votes) == 0) or ((count_positive_votes...
        return ((len(self.load("connectivity_votes")) == 0) or ((self._count_positive_votes(self.load("connectivity_votes")) / len(self.load("connectivity_votes"))) < CONNECTIVITY_THRESHOLD))

    def _check_message_sender_eq_LOAD_consumer(self) -> bool:
        # Schema: (message.sender == LOAD(consumer))...
        return (_msg.sender == self.load("consumer"))

    def _compute_vm_allocated_msg(self) -> Any:
        """Compute vm_allocated_msg."""
        # Schema: { session_id: LOAD(session_id), provider: peer_id, consumer:...
        return {"session_id": self.load("session_id"), "provider": self.peer_id, "consumer": self.load("consumer"), "vm_info": self.load("vm_info"), "allocated_at": self.load("vm_allocated_at"), "lock_result_hash": hash_data(self.load("lock_result")), "timestamp": self.current_time}

    def _compute_vm_cancelled_msg(self) -> Any:
        """Compute vm_cancelled_msg."""
        # Schema: { session_id: LOAD(session_id), provider: peer_id, cancelled...
        return {"session_id": self.load("session_id"), "provider": self.peer_id, "cancelled_at": self.load("cancelled_at"), "reason": self.load("termination_reason"), "actual_duration_seconds": (self.load("cancelled_at") - self.load("vm_allocated_at")), "timestamp": self.current_time}

    def _read_chain(self, chain: Any, query: str) -> Any:
        """READ: Read from a chain (own or cached peer chain)."""
        if chain is self.chain:
            chain_obj = self.chain
        elif isinstance(chain, str):
            # It's a peer_id - look up in cached_chains
            cached = self.load('cached_chains', {}).get(chain)
            if cached:
                # Return from cache based on query
                if query == 'head' or query == 'head_hash':
                    return cached.get('head_hash')
                elif query == 'balance':
                    return cached.get('balance', 0)
                return cached.get(query)
            # Fall back to chain's peer hash records
            if query == 'head' or query == 'head_hash':
                peer_block = self.chain.get_peer_hash(chain)
                if peer_block:
                    return peer_block.payload.get('hash')
            return None
        else:
            chain_obj = chain
        # Query the chain object
        if query == 'head' or query == 'head_hash':
            return chain_obj.head_hash if hasattr(chain_obj, 'head_hash') else None
        elif query == 'balance':
            return getattr(chain_obj, 'balance', 0)
        elif hasattr(chain_obj, query):
            return getattr(chain_obj, query)
        elif hasattr(chain_obj, 'get_' + query):
            return getattr(chain_obj, 'get_' + query)()
        return None

    def _chain_segment(self, chain: Any, target_hash: str) -> List[dict]:
        """CHAIN_SEGMENT: Extract chain segment up to target hash."""
        if chain is self.chain:
            chain_obj = self.chain
        elif hasattr(chain, 'to_segment'):
            chain_obj = chain
        else:
            return []
        if hasattr(chain_obj, 'to_segment'):
            return chain_obj.to_segment(target_hash)
        return []

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
            # It's a segment - delegate to Chain.state_from_segment
            return Chain.state_from_segment(chain_or_segment, target_hash)
        elif hasattr(chain_or_segment, 'get_state_at'):
            # It's a Chain object
            return chain_or_segment.get_state_at(target_hash)
        return None

    def _seeded_rng(self, seed: bytes) -> Any:
        """SEEDED_RNG: Create a seeded random number generator."""
        import random as _random
        return _random.Random(seed)

    def _seeded_sample(self, rng: Any, lst: list, n: int) -> list:
        """SEEDED_SAMPLE: Deterministically sample n items from list."""
        if not lst:
            return []
        return rng.sample(lst, min(n, len(lst)))

    def _sort(self, lst: list, key_fn: str = None) -> list:
        """SORT: Sort list by key."""
        return sorted(lst) if lst else []

    def _abort(self, reason: str) -> None:
        """ABORT: Exit state machine with error."""
        raise RuntimeError(f"ABORT: {reason}")

    def _concat(self, a: list, b: list) -> list:
        """CONCAT: Concatenate two lists."""
        return (a or []) + (b or [])

    def _has_key(self, d: dict, key: Any) -> bool:
        """HAS_KEY: Check if dict contains key (null-safe)."""
        if d is None:
            return False
        return key in d if isinstance(d, dict) else False

    def _COMPUTE_CONSENSUS(self, verdicts: List[str], threshold: int) -> str:
        """Compute COMPUTE_CONSENSUS."""
        accept_count = len([v for v in verdicts if (v == self.load("ACCEPT"))])
        return ("ACCEPT" if (accept_count >= threshold) else "REJECT")

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        return [r.get(field) for r in records]

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        return len(self._FILTER(items, predicate))

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        return (len([x for x in items if (x == item)]) > 0)

    def _REMOVE(self, items: List[Any], item: Any) -> List[Any]:
        """Compute REMOVE."""
        return [x for x in items if (x != item)]

    def _SET_EQUALS(self, a: List[Any], b: List[Any]) -> bool:
        """Compute SET_EQUALS."""
        a_not_in_b = len([x for x in a if (not self._CONTAINS(b, x))])
        b_not_in_a = len([x for x in b if (not self._CONTAINS(a, x))])
        return ((a_not_in_b == 0) and (b_not_in_a == 0))

    def _MIN(self, a: int, b: int) -> int:
        """Compute MIN."""
        return (a if (a < b) else b)

    def _MAX(self, a: int, b: int) -> int:
        """Compute MAX."""
        return (a if (a > b) else b)

    def _GET(self, d: Dict[str, Any], key: str, default: Any) -> Any:
        """Compute GET."""
        return (d.get(key) if self._has_key(d, key) else default)

    def _count_positive_votes(self, votes: List[Dict[str, Any]]) -> int:
        """Compute count_positive_votes."""
        return len([v for v in votes if (v.get("can_reach_vm") == True)])

    def _build_cabal_votes_map(self, votes: List[Dict[str, Any]]) -> Dict[str, bool]:
        """Compute build_cabal_votes_map."""
        result = {}
        for v in votes:
            result = v.get("can_reach_vm")
        return result

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
                _msg = msgs[0]
                self.store("vm_allocated_msg", _msg.payload)
                self.store("vm_allocated_at", _msg.payload.get("allocated_at"))
                self.transition_to(WitnessState.VERIFYING_VM)
                self.message_queue.remove(_msg)  # Only remove processed message


        elif self.state == WitnessState.VERIFYING_VM:
            # Auto transition
            # Compute: can_reach_vm = FunctionCallExpr(name='check_vm_connectivity', args=[FieldAccessExpr(object=Identifier(name='vm_allocated_msg', line=0, column=0), field='consumer_wireguard_endpoint', line=0, column=0)], line=0, column=0)
            self.store("can_reach_vm", self._compute_can_reach_vm())
            # Compute: can_see_consumer_connected = FunctionCallExpr(name='check_consumer_connected', args=[Identifier(name='session_id', line=0, column=0)], line=0, column=0)
            self.store("can_see_consumer_connected", self._compute_can_see_consumer_connected())
            self.store("witness", self.peer_id)
            # Compute: vote_data = StructLiteralExpr(fields={'session_id': FunctionCallExpr(name='LOAD', args=[Identifier(name='session_id', line=0, column=0)], line=0, column=0), 'witness': Identifier(name='peer_id', line=0, column=0), 'can_reach_vm': FunctionCallExpr(name='LOAD', args=[Identifier(name='can_reach_vm', line=0, column=0)], line=0, column=0), 'can_see_consumer_connected': FunctionCallExpr(name='LOAD', args=[Identifier(name='can_see_consumer_connected', line=0, column=0)], line=0, column=0), 'timestamp': FunctionCallExpr(name='NOW', args=[], line=0, column=0)}, spread=None, line=0, column=0)
            self.store("vote_data", self._compute_vote_data())
            # Compute: vote_signature = FunctionCallExpr(name='SIGN', args=[FunctionCallExpr(name='LOAD', args=[Identifier(name='vote_data', line=0, column=0)], line=0, column=0)], line=0, column=0)
            self.store("vote_signature", self._compute_vote_signature())
            # Compute: my_connectivity_vote = StructLiteralExpr(fields={'signature': FunctionCallExpr(name='LOAD', args=[Identifier(name='vote_signature', line=0, column=0)], line=0, column=0)}, spread=FunctionCallExpr(name='LOAD', args=[Identifier(name='vote_data', line=0, column=0)], line=0, column=0), line=0, column=0)
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
                _msg = msgs[0]
                _list = self.load("connectivity_votes") or []
                _list.append(_msg.payload)
                self.store("connectivity_votes", _list)
                self.transition_to(WitnessState.COLLECTING_VOTES)
                self.message_queue.remove(_msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONNECTIVITY_VOTE_TIMEOUT:
                self.transition_to(WitnessState.EVALUATING_CONNECTIVITY)

            # Auto transition with guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='other_witnesses', line=0, column=0)], line=0, column=0), op=<BinaryOperator.ADD: 1>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0)
            if self._check_LENGTH_connectivity_votes_gte_LENGTH_other_witnesses_1():
                self.transition_to(WitnessState.EVALUATING_CONNECTIVITY)

        elif self.state == WitnessState.EVALUATING_CONNECTIVITY:
            # Auto transition with guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GT: 8>, right=Literal(value=0, type='number', line=0, column=0), line=0, column=0), op=<BinaryOperator.AND: 11>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)
            if self._check_LENGTH_connectivity_votes_gt_0_and_count_positive_votes_conn():
                self.store("connectivity_verified", True)
                self.transition_to(WitnessState.MONITORING)
            # Auto transition with guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.EQ: 5>, right=Literal(value=0, type='number', line=0, column=0), line=0, column=0), op=<BinaryOperator.OR: 12>, right=BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='count_positive_votes', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=FunctionCallExpr(name='LENGTH', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), line=0, column=0), op=<BinaryOperator.LT: 7>, right=Identifier(name='CONNECTIVITY_THRESHOLD', line=0, column=0), line=0, column=0), line=0, column=0)
            elif self._check_LENGTH_connectivity_votes_eq_0_or_count_positive_votes_conne():
                self.store("connectivity_verified", False)
                self.store("abort_reason", "vm_unreachable")
                self.transition_to(WitnessState.VOTING_ABORT)

        elif self.state == WitnessState.MONITORING:
            # Check for VM_CANCELLED
            msgs = self.get_messages(MessageType.VM_CANCELLED)
            if msgs:
                _msg = msgs[0]
                self.store("vm_cancelled_msg", _msg.payload)
                self.store("actual_duration_seconds", _msg.payload.get("actual_duration_seconds"))
                self.store("termination_reason", _msg.payload.get("reason"))
                self.transition_to(WitnessState.ATTESTING)
                self.message_queue.remove(_msg)  # Only remove processed message

            # Check for MISUSE_ACCUSATION
            msgs = self.get_messages(MessageType.MISUSE_ACCUSATION)
            if msgs:
                _msg = msgs[0]
                self.store("misuse_accusation", _msg.payload)
                self.transition_to(WitnessState.HANDLING_MISUSE)
                self.message_queue.remove(_msg)  # Only remove processed message


        elif self.state == WitnessState.HANDLING_MISUSE:
            # Auto transition with guard: BinaryExpr(left=FieldAccessExpr(object=FunctionCallExpr(name='LOAD', args=[Identifier(name='misuse_accusation', line=0, column=0)], line=0, column=0), field='evidence', line=0, column=0), op=<BinaryOperator.NEQ: 6>, right=Literal(value='', type='string', line=0, column=0), line=0, column=0)
            if self._check_LOAD_misuse_accusation_evidence_neq():
                self.store("abort_reason", "consumer_misuse")
                self.transition_to(WitnessState.VOTING_ABORT)
            # Auto transition with guard: BinaryExpr(left=FieldAccessExpr(object=FunctionCallExpr(name='LOAD', args=[Identifier(name='misuse_accusation', line=0, column=0)], line=0, column=0), field='evidence', line=0, column=0), op=<BinaryOperator.EQ: 5>, right=Literal(value='', type='string', line=0, column=0), line=0, column=0)
            elif self._check_LOAD_misuse_accusation_evidence_eq():
                self.transition_to(WitnessState.MONITORING)

        elif self.state == WitnessState.VOTING_ABORT:
            # Auto transition
            # Compute: abort_vote_data = StructLiteralExpr(fields={'session_id': FunctionCallExpr(name='LOAD', args=[Identifier(name='session_id', line=0, column=0)], line=0, column=0), 'witness': Identifier(name='peer_id', line=0, column=0), 'reason': FunctionCallExpr(name='LOAD', args=[Identifier(name='abort_reason', line=0, column=0)], line=0, column=0), 'timestamp': FunctionCallExpr(name='NOW', args=[], line=0, column=0)}, spread=None, line=0, column=0)
            self.store("abort_vote_data", self._compute_abort_vote_data())
            # Compute: abort_vote_signature = FunctionCallExpr(name='SIGN', args=[FunctionCallExpr(name='LOAD', args=[Identifier(name='abort_vote_data', line=0, column=0)], line=0, column=0)], line=0, column=0)
            self.store("abort_vote_signature", self._compute_abort_vote_signature())
            # Compute: my_abort_vote = StructLiteralExpr(fields={'signature': FunctionCallExpr(name='LOAD', args=[Identifier(name='abort_vote_signature', line=0, column=0)], line=0, column=0)}, spread=FunctionCallExpr(name='LOAD', args=[Identifier(name='abort_vote_data', line=0, column=0)], line=0, column=0), line=0, column=0)
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
                _msg = msgs[0]
                _list = self.load("abort_votes") or []
                _list.append(_msg.payload)
                self.store("abort_votes", _list)
                self.transition_to(WitnessState.COLLECTING_ABORT_VOTES)
                self.message_queue.remove(_msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > ABORT_VOTE_TIMEOUT:
                self.transition_to(WitnessState.MONITORING)

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > ABORT_VOTE_TIMEOUT:
                self.store("session_aborted", True)
                self.store("termination_reason", self.load("abort_reason"))
                self.transition_to(WitnessState.ATTESTING)

            # Auto transition with guard: BinaryExpr(left=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='abort_votes', line=0, column=0)], line=0, column=0), op=<BinaryOperator.DIV: 4>, right=BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='other_witnesses', line=0, column=0)], line=0, column=0), op=<BinaryOperator.ADD: 1>, right=Literal(value=1, type='number', line=0, column=0), line=0, column=0), line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='ABORT_THRESHOLD', line=0, column=0), line=0, column=0)
            if self._check_LENGTH_abort_votes_LENGTH_other_witnesses_1_gte_ABORT_THRESH():
                self.store("session_aborted", True)
                self.store("termination_reason", self.load("abort_reason"))
                self.transition_to(WitnessState.ATTESTING)

        elif self.state == WitnessState.ATTESTING:
            # Auto transition
            # Compute: attestation = StructLiteralExpr(fields={'session_id': FunctionCallExpr(name='LOAD', args=[Identifier(name='session_id', line=0, column=0)], line=0, column=0), 'vm_allocated_hash': FunctionCallExpr(name='HASH', args=[FunctionCallExpr(name='LOAD', args=[Identifier(name='vm_allocated_msg', line=0, column=0)], line=0, column=0)], line=0, column=0), 'vm_cancelled_hash': FunctionCallExpr(name='HASH', args=[FunctionCallExpr(name='LOAD', args=[Identifier(name='vm_cancelled_msg', line=0, column=0)], line=0, column=0)], line=0, column=0), 'connectivity_verified': FunctionCallExpr(name='LOAD', args=[Identifier(name='connectivity_verified', line=0, column=0)], line=0, column=0), 'actual_duration_seconds': FunctionCallExpr(name='LOAD', args=[Identifier(name='actual_duration_seconds', line=0, column=0)], line=0, column=0), 'termination_reason': FunctionCallExpr(name='LOAD', args=[Identifier(name='termination_reason', line=0, column=0)], line=0, column=0), 'cabal_votes': FunctionCallExpr(name='LOAD', args=[Identifier(name='connectivity_votes', line=0, column=0)], line=0, column=0), 'cabal_signatures': ListLiteralExpr(elements=[], line=0, column=0), 'created_at': FunctionCallExpr(name='NOW', args=[], line=0, column=0)}, spread=None, line=0, column=0)
            self.store("attestation", self._compute_attestation())
            # Compute: my_signature = FunctionCallExpr(name='SIGN', args=[FunctionCallExpr(name='LOAD', args=[Identifier(name='attestation', line=0, column=0)], line=0, column=0)], line=0, column=0)
            self.store("my_signature", self._compute_my_signature())
            self.store("attestation_signatures", [{"witness": self.peer_id, "signature": self.load("my_signature")}])
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
                _msg = msgs[0]
                _list = self.load("attestation_signatures") or []
                _list.append(_msg.payload.get("attestation").get("cabal_signatures"))
                self.store("attestation_signatures", _list)
                self.transition_to(WitnessState.COLLECTING_ATTESTATION_SIGS)
                self.message_queue.remove(_msg)  # Only remove processed message

            # Auto transition with guard: BinaryExpr(left=FunctionCallExpr(name='LENGTH', args=[Identifier(name='attestation_signatures', line=0, column=0)], line=0, column=0), op=<BinaryOperator.GTE: 10>, right=Identifier(name='ATTESTATION_THRESHOLD', line=0, column=0), line=0, column=0)
            if self._check_LENGTH_attestation_signatures_gte_ATTESTATION_THRESHOLD():
                self.transition_to(WitnessState.PROPAGATING_ATTESTATION)

        elif self.state == WitnessState.PROPAGATING_ATTESTATION:
            # Auto transition
            # Compute: final_attestation = StructLiteralExpr(fields={'cabal_signatures': FunctionCallExpr(name='LOAD', args=[Identifier(name='attestation_signatures', line=0, column=0)], line=0, column=0)}, spread=FunctionCallExpr(name='LOAD', args=[Identifier(name='attestation', line=0, column=0)], line=0, column=0), line=0, column=0)
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

    def _check_message_payload_witness_neq_peer_id(self) -> bool:
        # Schema: (message.payload.witness != peer_id)...
        return (_msg.payload.get("witness") != self.peer_id)

    def _check_LENGTH_connectivity_votes_gte_LENGTH_other_witnesses_1(self) -> bool:
        # Schema: (LENGTH(connectivity_votes) >= (LENGTH(other_witnesses) + 1)...
        return (len(self.load("connectivity_votes")) >= (len(self.load("other_witnesses")) + 1))

    def _check_LENGTH_connectivity_votes_gt_0_and_count_positive_votes_conn(self) -> bool:
        # Schema: ((LENGTH(connectivity_votes) > 0) and ((count_positive_votes...
        return ((len(self.load("connectivity_votes")) > 0) and ((self._count_positive_votes(self.load("connectivity_votes")) / len(self.load("connectivity_votes"))) >= CONNECTIVITY_THRESHOLD))

    def _check_LENGTH_connectivity_votes_eq_0_or_count_positive_votes_conne(self) -> bool:
        # Schema: ((LENGTH(connectivity_votes) == 0) or ((count_positive_votes...
        return ((len(self.load("connectivity_votes")) == 0) or ((self._count_positive_votes(self.load("connectivity_votes")) / len(self.load("connectivity_votes"))) < CONNECTIVITY_THRESHOLD))

    def _check_LOAD_misuse_accusation_evidence_neq(self) -> bool:
        # Schema: (LOAD(misuse_accusation).evidence != "")...
        return (self.load("misuse_accusation").get("evidence") != "")

    def _check_LOAD_misuse_accusation_evidence_eq(self) -> bool:
        # Schema: (LOAD(misuse_accusation).evidence == "")...
        return (self.load("misuse_accusation").get("evidence") == "")

    def _check_LENGTH_abort_votes_LENGTH_other_witnesses_1_gte_ABORT_THRESH(self) -> bool:
        # Schema: ((LENGTH(abort_votes) / (LENGTH(other_witnesses) + 1)) >= AB...
        return ((len(self.load("abort_votes")) / (len(self.load("other_witnesses")) + 1)) >= ABORT_THRESHOLD)

    def _check_LENGTH_abort_votes_LENGTH_other_witnesses_1_lt_ABORT_THRESHO(self) -> bool:
        # Schema: ((LENGTH(abort_votes) / (LENGTH(other_witnesses) + 1)) < ABO...
        return ((len(self.load("abort_votes")) / (len(self.load("other_witnesses")) + 1)) < ABORT_THRESHOLD)

    def _check_LENGTH_attestation_signatures_gte_ATTESTATION_THRESHOLD(self) -> bool:
        # Schema: (LENGTH(attestation_signatures) >= ATTESTATION_THRESHOLD)...
        return (len(self.load("attestation_signatures")) >= ATTESTATION_THRESHOLD)

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
        # Schema: { session_id: LOAD(session_id), witness: peer_id, can_reach_...
        return {"session_id": self.load("session_id"), "witness": self.peer_id, "can_reach_vm": self.load("can_reach_vm"), "can_see_consumer_connected": self.load("can_see_consumer_connected"), "timestamp": self.current_time}

    def _compute_vote_signature(self) -> Any:
        """Compute vote_signature."""
        # Schema: SIGN(LOAD(vote_data))...
        return sign(self.chain.private_key, hash_data(self.load("vote_data")))

    def _compute_my_connectivity_vote(self) -> Any:
        """Compute my_connectivity_vote."""
        # Schema: { ...LOAD(vote_data), signature: LOAD(vote_signature) }...
        return {**self.load("vote_data"), "signature": self.load("vote_signature")}

    def _compute_abort_vote_data(self) -> Any:
        """Compute abort_vote_data."""
        # Schema: { session_id: LOAD(session_id), witness: peer_id, reason: LO...
        return {"session_id": self.load("session_id"), "witness": self.peer_id, "reason": self.load("abort_reason"), "timestamp": self.current_time}

    def _compute_abort_vote_signature(self) -> Any:
        """Compute abort_vote_signature."""
        # Schema: SIGN(LOAD(abort_vote_data))...
        return sign(self.chain.private_key, hash_data(self.load("abort_vote_data")))

    def _compute_my_abort_vote(self) -> Any:
        """Compute my_abort_vote."""
        # Schema: { ...LOAD(abort_vote_data), signature: LOAD(abort_vote_signa...
        return {**self.load("abort_vote_data"), "signature": self.load("abort_vote_signature")}

    def _compute_attestation(self) -> Any:
        """Compute attestation."""
        # Schema: { session_id: LOAD(session_id), vm_allocated_hash: HASH(LOAD...
        return {"session_id": self.load("session_id"), "vm_allocated_hash": hash_data(self.load("vm_allocated_msg")), "vm_cancelled_hash": hash_data(self.load("vm_cancelled_msg")), "connectivity_verified": self.load("connectivity_verified"), "actual_duration_seconds": self.load("actual_duration_seconds"), "termination_reason": self.load("termination_reason"), "cabal_votes": self.load("connectivity_votes"), "cabal_signatures": [], "created_at": self.current_time}

    def _compute_my_signature(self) -> Any:
        """Compute my_signature."""
        # Schema: SIGN(LOAD(attestation))...
        return sign(self.chain.private_key, hash_data(self.load("attestation")))

    def _compute_final_attestation(self) -> Any:
        """Compute final_attestation."""
        # Schema: { ...LOAD(attestation), cabal_signatures: LOAD(attestation_s...
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

    def _read_chain(self, chain: Any, query: str) -> Any:
        """READ: Read from a chain (own or cached peer chain)."""
        if chain is self.chain:
            chain_obj = self.chain
        elif isinstance(chain, str):
            # It's a peer_id - look up in cached_chains
            cached = self.load('cached_chains', {}).get(chain)
            if cached:
                # Return from cache based on query
                if query == 'head' or query == 'head_hash':
                    return cached.get('head_hash')
                elif query == 'balance':
                    return cached.get('balance', 0)
                return cached.get(query)
            # Fall back to chain's peer hash records
            if query == 'head' or query == 'head_hash':
                peer_block = self.chain.get_peer_hash(chain)
                if peer_block:
                    return peer_block.payload.get('hash')
            return None
        else:
            chain_obj = chain
        # Query the chain object
        if query == 'head' or query == 'head_hash':
            return chain_obj.head_hash if hasattr(chain_obj, 'head_hash') else None
        elif query == 'balance':
            return getattr(chain_obj, 'balance', 0)
        elif hasattr(chain_obj, query):
            return getattr(chain_obj, query)
        elif hasattr(chain_obj, 'get_' + query):
            return getattr(chain_obj, 'get_' + query)()
        return None

    def _chain_segment(self, chain: Any, target_hash: str) -> List[dict]:
        """CHAIN_SEGMENT: Extract chain segment up to target hash."""
        if chain is self.chain:
            chain_obj = self.chain
        elif hasattr(chain, 'to_segment'):
            chain_obj = chain
        else:
            return []
        if hasattr(chain_obj, 'to_segment'):
            return chain_obj.to_segment(target_hash)
        return []

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
            # It's a segment - delegate to Chain.state_from_segment
            return Chain.state_from_segment(chain_or_segment, target_hash)
        elif hasattr(chain_or_segment, 'get_state_at'):
            # It's a Chain object
            return chain_or_segment.get_state_at(target_hash)
        return None

    def _seeded_rng(self, seed: bytes) -> Any:
        """SEEDED_RNG: Create a seeded random number generator."""
        import random as _random
        return _random.Random(seed)

    def _seeded_sample(self, rng: Any, lst: list, n: int) -> list:
        """SEEDED_SAMPLE: Deterministically sample n items from list."""
        if not lst:
            return []
        return rng.sample(lst, min(n, len(lst)))

    def _sort(self, lst: list, key_fn: str = None) -> list:
        """SORT: Sort list by key."""
        return sorted(lst) if lst else []

    def _abort(self, reason: str) -> None:
        """ABORT: Exit state machine with error."""
        raise RuntimeError(f"ABORT: {reason}")

    def _concat(self, a: list, b: list) -> list:
        """CONCAT: Concatenate two lists."""
        return (a or []) + (b or [])

    def _has_key(self, d: dict, key: Any) -> bool:
        """HAS_KEY: Check if dict contains key (null-safe)."""
        if d is None:
            return False
        return key in d if isinstance(d, dict) else False

    def _COMPUTE_CONSENSUS(self, verdicts: List[str], threshold: int) -> str:
        """Compute COMPUTE_CONSENSUS."""
        accept_count = len([v for v in verdicts if (v == self.load("ACCEPT"))])
        return ("ACCEPT" if (accept_count >= threshold) else "REJECT")

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        return [r.get(field) for r in records]

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        return len(self._FILTER(items, predicate))

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        return (len([x for x in items if (x == item)]) > 0)

    def _REMOVE(self, items: List[Any], item: Any) -> List[Any]:
        """Compute REMOVE."""
        return [x for x in items if (x != item)]

    def _SET_EQUALS(self, a: List[Any], b: List[Any]) -> bool:
        """Compute SET_EQUALS."""
        a_not_in_b = len([x for x in a if (not self._CONTAINS(b, x))])
        b_not_in_a = len([x for x in b if (not self._CONTAINS(a, x))])
        return ((a_not_in_b == 0) and (b_not_in_a == 0))

    def _MIN(self, a: int, b: int) -> int:
        """Compute MIN."""
        return (a if (a < b) else b)

    def _MAX(self, a: int, b: int) -> int:
        """Compute MAX."""
        return (a if (a > b) else b)

    def _GET(self, d: Dict[str, Any], key: str, default: Any) -> Any:
        """Compute GET."""
        return (d.get(key) if self._has_key(d, key) else default)

    def _count_positive_votes(self, votes: List[Dict[str, Any]]) -> int:
        """Compute count_positive_votes."""
        return len([v for v in votes if (v.get("can_reach_vm") == True)])

    def _build_cabal_votes_map(self, votes: List[Dict[str, Any]]) -> Dict[str, bool]:
        """Compute build_cabal_votes_map."""
        result = {}
        for v in votes:
            result = v.get("can_reach_vm")
        return result

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
                _msg = msgs[0]
                self.store("vm_info", _msg.payload.get("vm_info"))
                self.transition_to(ConsumerState.CONNECTING)
                self.message_queue.remove(_msg)  # Only remove processed message


        elif self.state == ConsumerState.CONNECTING:
            # Auto transition
            self.store("connected_at", self.current_time)
            self.transition_to(ConsumerState.CONNECTED)

        elif self.state == ConsumerState.CONNECTED:
            # Check for SESSION_TERMINATED
            msgs = self.get_messages(MessageType.SESSION_TERMINATED)
            if msgs:
                _msg = msgs[0]
                self.store("termination_reason", _msg.payload.get("reason"))
                self.transition_to(ConsumerState.SESSION_ENDED)
                self.message_queue.remove(_msg)  # Only remove processed message

            # Check for ATTESTATION_RESULT
            msgs = self.get_messages(MessageType.ATTESTATION_RESULT)
            if msgs:
                _msg = msgs[0]
                self.store("attestation", _msg.payload.get("attestation"))
                self.transition_to(ConsumerState.CONNECTED)
                self.message_queue.remove(_msg)  # Only remove processed message


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
                _msg = msgs[0]
                self.store("attestation", _msg.payload.get("attestation"))
                self.transition_to(ConsumerState.SESSION_ENDED)
                self.message_queue.remove(_msg)  # Only remove processed message


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

    def _read_chain(self, chain: Any, query: str) -> Any:
        """READ: Read from a chain (own or cached peer chain)."""
        if chain is self.chain:
            chain_obj = self.chain
        elif isinstance(chain, str):
            # It's a peer_id - look up in cached_chains
            cached = self.load('cached_chains', {}).get(chain)
            if cached:
                # Return from cache based on query
                if query == 'head' or query == 'head_hash':
                    return cached.get('head_hash')
                elif query == 'balance':
                    return cached.get('balance', 0)
                return cached.get(query)
            # Fall back to chain's peer hash records
            if query == 'head' or query == 'head_hash':
                peer_block = self.chain.get_peer_hash(chain)
                if peer_block:
                    return peer_block.payload.get('hash')
            return None
        else:
            chain_obj = chain
        # Query the chain object
        if query == 'head' or query == 'head_hash':
            return chain_obj.head_hash if hasattr(chain_obj, 'head_hash') else None
        elif query == 'balance':
            return getattr(chain_obj, 'balance', 0)
        elif hasattr(chain_obj, query):
            return getattr(chain_obj, query)
        elif hasattr(chain_obj, 'get_' + query):
            return getattr(chain_obj, 'get_' + query)()
        return None

    def _chain_segment(self, chain: Any, target_hash: str) -> List[dict]:
        """CHAIN_SEGMENT: Extract chain segment up to target hash."""
        if chain is self.chain:
            chain_obj = self.chain
        elif hasattr(chain, 'to_segment'):
            chain_obj = chain
        else:
            return []
        if hasattr(chain_obj, 'to_segment'):
            return chain_obj.to_segment(target_hash)
        return []

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
            # It's a segment - delegate to Chain.state_from_segment
            return Chain.state_from_segment(chain_or_segment, target_hash)
        elif hasattr(chain_or_segment, 'get_state_at'):
            # It's a Chain object
            return chain_or_segment.get_state_at(target_hash)
        return None

    def _seeded_rng(self, seed: bytes) -> Any:
        """SEEDED_RNG: Create a seeded random number generator."""
        import random as _random
        return _random.Random(seed)

    def _seeded_sample(self, rng: Any, lst: list, n: int) -> list:
        """SEEDED_SAMPLE: Deterministically sample n items from list."""
        if not lst:
            return []
        return rng.sample(lst, min(n, len(lst)))

    def _sort(self, lst: list, key_fn: str = None) -> list:
        """SORT: Sort list by key."""
        return sorted(lst) if lst else []

    def _abort(self, reason: str) -> None:
        """ABORT: Exit state machine with error."""
        raise RuntimeError(f"ABORT: {reason}")

    def _concat(self, a: list, b: list) -> list:
        """CONCAT: Concatenate two lists."""
        return (a or []) + (b or [])

    def _has_key(self, d: dict, key: Any) -> bool:
        """HAS_KEY: Check if dict contains key (null-safe)."""
        if d is None:
            return False
        return key in d if isinstance(d, dict) else False

    def _COMPUTE_CONSENSUS(self, verdicts: List[str], threshold: int) -> str:
        """Compute COMPUTE_CONSENSUS."""
        accept_count = len([v for v in verdicts if (v == self.load("ACCEPT"))])
        return ("ACCEPT" if (accept_count >= threshold) else "REJECT")

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        return [r.get(field) for r in records]

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        return len(self._FILTER(items, predicate))

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        return (len([x for x in items if (x == item)]) > 0)

    def _REMOVE(self, items: List[Any], item: Any) -> List[Any]:
        """Compute REMOVE."""
        return [x for x in items if (x != item)]

    def _SET_EQUALS(self, a: List[Any], b: List[Any]) -> bool:
        """Compute SET_EQUALS."""
        a_not_in_b = len([x for x in a if (not self._CONTAINS(b, x))])
        b_not_in_a = len([x for x in b if (not self._CONTAINS(a, x))])
        return ((a_not_in_b == 0) and (b_not_in_a == 0))

    def _MIN(self, a: int, b: int) -> int:
        """Compute MIN."""
        return (a if (a < b) else b)

    def _MAX(self, a: int, b: int) -> int:
        """Compute MAX."""
        return (a if (a > b) else b)

    def _GET(self, d: Dict[str, Any], key: str, default: Any) -> Any:
        """Compute GET."""
        return (d.get(key) if self._has_key(d, key) else default)

    def _count_positive_votes(self, votes: List[Dict[str, Any]]) -> int:
        """Compute count_positive_votes."""
        return len([v for v in votes if (v.get("can_reach_vm") == True)])

    def _build_cabal_votes_map(self, votes: List[Dict[str, Any]]) -> Dict[str, bool]:
        """Compute build_cabal_votes_map."""
        result = {}
        for v in votes:
            result = v.get("can_reach_vm")
        return result

    def _check_vm_connectivity(self, vm_endpoint: str) -> bool:
        """Compute check_vm_connectivity."""
        # Native function from: omerta.native.vm_connectivity
        return check_vm_connectivity(vm_endpoint)

    def _check_consumer_connected(self, session_id: str) -> bool:
        """Compute check_consumer_connected."""
        # Native function from: omerta.native.vm_connectivity
        return check_consumer_connected(session_id)
