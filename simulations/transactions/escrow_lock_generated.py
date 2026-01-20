"""
Transaction 00: Escrow Lock / Top-up

Lock funds with distributed witness consensus for a compute session

GENERATED FROM transaction.omt
"""

from enum import Enum, auto
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Any

from ..chain.primitives import (
    Chain, Block, BlockType,
    hash_data, sign, verify_sig, generate_id, random_bytes
)


# =============================================================================
# Parameters
# =============================================================================

WITNESS_COUNT = 5  # Initial witnesses to recruit (count)
WITNESS_THRESHOLD = 3  # Minimum for consensus (count)
WITNESS_COMMITMENT_TIMEOUT = 30  # Seconds for provider to respond with witnesses (seconds)
LOCK_TIMEOUT = 300  # Seconds for consumer to complete lock (provider waiting) (seconds)
PRELIMINARY_TIMEOUT = 30  # Seconds to collect preliminaries (seconds)
CONSENSUS_TIMEOUT = 60  # Seconds to reach consensus (seconds)
RECRUITMENT_TIMEOUT = 180  # Seconds for full recruitment (seconds)
CONSUMER_SIGNATURE_TIMEOUT = 60  # Seconds for consumer to counter-sign (seconds)
LIVENESS_CHECK_INTERVAL = 300  # Seconds between liveness checks (seconds)
LIVENESS_RESPONSE_TIMEOUT = 30  # Seconds to respond to ping (seconds)
REPLACEMENT_TIMEOUT = 120  # Seconds to get replacement witness ack (seconds)
MAX_CHAIN_AGE = 3600  # Max age of chain knowledge (seconds)
CONSENSUS_THRESHOLD = 0.67  # Fraction needed to decide (fraction)
MAX_RECRUITMENT_ROUNDS = 3  # Max times to recruit more witnesses (count)
MIN_HIGH_TRUST_WITNESSES = 2  # Minimum high-trust witnesses for fairness (count)
MAX_PRIOR_INTERACTIONS = 5  # Max prior interactions with consumer for fairness (count)
HIGH_TRUST_THRESHOLD = 1  # Trust score threshold for high-trust classification (fraction)

# =============================================================================
# Enums
# =============================================================================

class WitnessVerdict(Enum):
    """Witness verdict on lock request"""
    ACCEPT = auto()
    REJECT = auto()
    NEED_MORE_INFO = auto()

class LockStatus(Enum):
    """Final status of lock attempt"""
    ACCEPTED = auto()
    REJECTED = auto()
    CONSUMER_ABANDONED = auto()

# =============================================================================
# Message Types
# =============================================================================

class MessageType(Enum):
    """Types of messages exchanged in this transaction."""
    LOCK_INTENT = auto()
    WITNESS_SELECTION_COMMITMENT = auto()
    LOCK_REJECTED = auto()
    WITNESS_REQUEST = auto()
    CONSUMER_SIGNED_LOCK = auto()
    WITNESS_PRELIMINARY = auto()
    WITNESS_CHAIN_SYNC_REQUEST = auto()
    WITNESS_CHAIN_SYNC_RESPONSE = auto()
    WITNESS_FINAL_VOTE = auto()
    WITNESS_RECRUIT_REQUEST = auto()
    LOCK_RESULT_FOR_SIGNATURE = auto()
    BALANCE_UPDATE_BROADCAST = auto()
    LIVENESS_PING = auto()
    LIVENESS_PONG = auto()
    TOPUP_INTENT = auto()
    TOPUP_RESULT_FOR_SIGNATURE = auto()
    CONSUMER_SIGNED_TOPUP = auto()
    TOPUP_VOTE = auto()


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

    def in_state(self, state_name: str) -> bool:
        """Check if actor is in a named state."""
        return self.state.name == state_name

    def tick(self, current_time: float) -> List[Message]:
        raise NotImplementedError


# =============================================================================
# Consumer
# =============================================================================

class ConsumerState(Enum):
    """Consumer states."""
    IDLE = auto()  # Waiting to initiate lock
    SENDING_LOCK_INTENT = auto()  # Sending lock intent to provider
    WAITING_FOR_WITNESS_COMMITMENT = auto()  # Waiting for provider witness selection
    VERIFYING_PROVIDER_CHAIN = auto()  # Verifying provider's chain segment
    VERIFYING_WITNESSES = auto()  # Verifying witness selection is correct
    SENDING_REQUESTS = auto()  # Sending requests to witnesses
    WAITING_FOR_RESULT = auto()  # Waiting for witness consensus
    REVIEWING_RESULT = auto()  # Reviewing lock result
    SIGNING_RESULT = auto()  # Counter-signing the lock
    LOCKED = auto()  # Funds successfully locked
    FAILED = auto()  # Lock failed
    SENDING_TOPUP = auto()  # Sending top-up request
    WAITING_FOR_TOPUP_RESULT = auto()  # Waiting for cabal top-up consensus
    REVIEWING_TOPUP_RESULT = auto()  # Reviewing top-up result
    SIGNING_TOPUP = auto()  # Counter-signing top-up

@dataclass
class Consumer(Actor):
    """Party paying for service"""

    state: ConsumerState = ConsumerState.IDLE

    def initiate_lock(self, provider: str, amount: int):
        """Start a new escrow lock"""
        if self.state not in (ConsumerState.IDLE,):
            raise ValueError(f"Cannot initiate_lock in state {self.state}")

        self.store("provider", provider)
        self.store("amount", amount)
        self.store("consumer", self.peer_id)
        # Compute: session_id = HASH(peer_id + provider + NOW())
        self.store("session_id", self._compute_session_id())
        # Compute: consumer_nonce = RANDOM_BYTES(32)
        self.store("consumer_nonce", self._compute_consumer_nonce())
        # Compute: provider_chain_checkpoint = READ(provider, "head_hash")
        self.store("provider_chain_checkpoint", self._compute_provider_chain_checkpoint())
        if self._check_provider_chain_checkpoint_neq_null():
            self.transition_to(ConsumerState.SENDING_LOCK_INTENT)
        else:
            self.store("provider", provider)
            self.store("amount", amount)
            self.store("consumer", self.peer_id)
            self.store("reject_reason", 'no_prior_provider_checkpoint')
            self.transition_to(ConsumerState.FAILED)

    def initiate_topup(self, additional_amount: int):
        """Add funds to existing escrow"""
        if self.state not in (ConsumerState.LOCKED,):
            raise ValueError(f"Cannot initiate_topup in state {self.state}")

        self.store("additional_amount", additional_amount)
        # Compute: current_lock_hash = HASH(lock_result)
        self.store("current_lock_hash", self._compute_current_lock_hash())
        self.transition_to(ConsumerState.SENDING_TOPUP)

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ConsumerState.IDLE:
            pass

        elif self.state == ConsumerState.SENDING_LOCK_INTENT:
            # Auto transition
            msg_payload = self._build_lock_intent_payload()
            outgoing.append(Message(
                msg_type=MessageType.LOCK_INTENT,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("provider"),
            ))
            self.store("intent_sent_at", self.current_time)
            self.transition_to(ConsumerState.WAITING_FOR_WITNESS_COMMITMENT)

        elif self.state == ConsumerState.WAITING_FOR_WITNESS_COMMITMENT:
            # Check for WITNESS_SELECTION_COMMITMENT
            msgs = self.get_messages(MessageType.WITNESS_SELECTION_COMMITMENT)
            if msgs:
                msg = msgs[0]
                self.store("provider_nonce", msg.payload.get("provider_nonce"))
                self.store("provider_chain_segment", msg.payload.get("provider_chain_segment"))
                self.store("selection_inputs", msg.payload.get("selection_inputs"))
                self.store("proposed_witnesses", msg.payload.get("witnesses"))
                # Compute: chain_segment_valid_and_contains_checkpoint = VERIFY_CHAIN_SEGMENT(provider_chain_segment) and CHAIN_CONTAINS_HASH(provider_chain_segment, provider_chain_checkpoint)
                self.store("chain_segment_valid_and_contains_checkpoint", self._compute_chain_segment_valid_and_contains_checkpoint())
                self.transition_to(ConsumerState.VERIFYING_PROVIDER_CHAIN)
                self.message_queue.remove(msg)  # Only remove processed message

            # Check for LOCK_REJECTED
            msgs = self.get_messages(MessageType.LOCK_REJECTED)
            if msgs:
                msg = msgs[0]
                self.store("reject_reason", msg.payload.get("reason"))
                self.transition_to(ConsumerState.FAILED)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > WITNESS_COMMITMENT_TIMEOUT:
                self.store("reject_reason", 'provider_timeout')
                self.transition_to(ConsumerState.FAILED)


        elif self.state == ConsumerState.VERIFYING_PROVIDER_CHAIN:
            # Auto transition with guard: chain_segment_valid_and_contains_checkpoint
            if self._check_chain_segment_valid_and_contains_checkpoint():
                # Compute: verified_chain_state = CHAIN_STATE_AT(provider_chain_segment, provider_chain_checkpoint)
                self.store("verified_chain_state", self._compute_verified_chain_state())
                # Compute: witness_selection_valid = VERIFY_WITNESS_SELECTION(proposed_witnesses, selection_inputs, session_id, provider_nonce, consumer_nonce)
                self.store("witness_selection_valid", self._compute_witness_selection_valid())
                self.transition_to(ConsumerState.VERIFYING_WITNESSES)

        elif self.state == ConsumerState.VERIFYING_WITNESSES:
            # Auto transition with guard: witness_selection_valid
            if self._check_witness_selection_valid():
                self.store("witnesses", self.load("proposed_witnesses"))
                self.transition_to(ConsumerState.SENDING_REQUESTS)

        elif self.state == ConsumerState.SENDING_REQUESTS:
            # Auto transition
            for recipient in self.load("witnesses", []):
                msg_payload = self._build_witness_request_payload()
                outgoing.append(Message(
                    msg_type=MessageType.WITNESS_REQUEST,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.store("requests_sent_at", self.current_time)
            self.transition_to(ConsumerState.WAITING_FOR_RESULT)

        elif self.state == ConsumerState.WAITING_FOR_RESULT:
            # Check for LOCK_RESULT_FOR_SIGNATURE
            msgs = self.get_messages(MessageType.LOCK_RESULT_FOR_SIGNATURE)
            if msgs:
                msg = msgs[0]
                self.store("pending_result", msg.payload.get("result"))
                self.store("result_sender", msg.sender)
                # Compute: result_valid_and_accepted = VALIDATE_LOCK_RESULT(pending_result, session_id, amount)
                self.store("result_valid_and_accepted", self._compute_result_valid_and_accepted())
                self.transition_to(ConsumerState.REVIEWING_RESULT)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > RECRUITMENT_TIMEOUT:
                self.store("reject_reason", 'witness_timeout')
                self.transition_to(ConsumerState.FAILED)


        elif self.state == ConsumerState.REVIEWING_RESULT:
            # Auto transition with guard: result_valid_and_accepted
            if self._check_result_valid_and_accepted():
                self.transition_to(ConsumerState.SIGNING_RESULT)
            # Auto transition with guard: NOT result_valid_and_accepted
            elif self._check_NOT_result_valid_and_accepted():
                self.store("reject_reason", 'lock_rejected')
                self.transition_to(ConsumerState.FAILED)

        elif self.state == ConsumerState.SIGNING_RESULT:
            # Auto transition
            # Compute: consumer_signature = SIGN(pending_result)
            self.store("consumer_signature", self._compute_consumer_signature())
            self.store("lock_result", {**self.load("pending_result"), "consumer_signature": self.load("consumer_signature")})
            self.chain.append(
                BlockType.BALANCE_LOCK,
                self._build_balance_lock_payload(),
                current_time,
            )
            for recipient in self.load("witnesses", []):
                msg_payload = self._build_consumer_signed_lock_payload()
                outgoing.append(Message(
                    msg_type=MessageType.CONSUMER_SIGNED_LOCK,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.store("total_escrowed", self.load("amount"))
            self.transition_to(ConsumerState.LOCKED)

        elif self.state == ConsumerState.LOCKED:
            # Check for LIVENESS_PING
            msgs = self.get_messages(MessageType.LIVENESS_PING)
            if msgs:
                msg = msgs[0]
                self.store("from_witness", self.peer_id)
                msg_payload = self._build_liveness_pong_payload()
                outgoing.append(Message(
                    msg_type=MessageType.LIVENESS_PONG,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=msg.sender,
                ))
                self.transition_to(ConsumerState.LOCKED)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == ConsumerState.FAILED:
            # Lock failed
            pass

        elif self.state == ConsumerState.SENDING_TOPUP:
            # Auto transition
            for recipient in self.load("witnesses", []):
                msg_payload = self._build_topup_intent_payload()
                outgoing.append(Message(
                    msg_type=MessageType.TOPUP_INTENT,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.store("topup_sent_at", self.current_time)
            self.transition_to(ConsumerState.WAITING_FOR_TOPUP_RESULT)

        elif self.state == ConsumerState.WAITING_FOR_TOPUP_RESULT:
            # Check for TOPUP_RESULT_FOR_SIGNATURE
            msgs = self.get_messages(MessageType.TOPUP_RESULT_FOR_SIGNATURE)
            if msgs:
                msg = msgs[0]
                self.store("pending_topup_result", msg.payload.get("topup_result"))
                # Compute: topup_result_valid = VALIDATE_TOPUP_RESULT(pending_topup_result, session_id, additional_amount)
                self.store("topup_result_valid", self._compute_topup_result_valid())
                self.transition_to(ConsumerState.REVIEWING_TOPUP_RESULT)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONSENSUS_TIMEOUT:
                self.store("topup_failed_reason", 'timeout')
                self.transition_to(ConsumerState.LOCKED)


        elif self.state == ConsumerState.REVIEWING_TOPUP_RESULT:
            # Auto transition with guard: topup_result_valid
            if self._check_topup_result_valid():
                self.transition_to(ConsumerState.SIGNING_TOPUP)

        elif self.state == ConsumerState.SIGNING_TOPUP:
            # Auto transition
            # Compute: consumer_signature = SIGN(pending_topup_result)
            self.store("consumer_signature", self._compute_consumer_signature())
            self.store("topup_result", {**self.load("pending_topup_result"), "consumer_signature": self.load("consumer_signature")})
            self.chain.append(
                BlockType.BALANCE_TOPUP,
                self._build_balance_topup_payload(),
                current_time,
            )
            for recipient in self.load("witnesses", []):
                msg_payload = self._build_consumer_signed_topup_payload()
                outgoing.append(Message(
                    msg_type=MessageType.CONSUMER_SIGNED_TOPUP,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.store("total_escrowed", self.load("total_escrowed") + self.load("additional_amount"))
            self.transition_to(ConsumerState.LOCKED)

        return outgoing

    def _build_consumer_signed_lock_payload(self) -> Dict[str, Any]:
        """Build payload for CONSUMER_SIGNED_LOCK message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "consumer_signature": self._serialize_value(self.load("consumer_signature")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_lock_intent_payload(self) -> Dict[str, Any]:
        """Build payload for LOCK_INTENT message."""
        payload = {
            "consumer": self._serialize_value(self.load("consumer")),
            "provider": self._serialize_value(self.load("provider")),
            "amount": self._serialize_value(self.load("amount")),
            "session_id": self._serialize_value(self.load("session_id")),
            "consumer_nonce": self._serialize_value(self.load("consumer_nonce")),
            "provider_chain_checkpoint": self._serialize_value(self.load("provider_chain_checkpoint")),
            "checkpoint_timestamp": self._serialize_value(self.load("checkpoint_timestamp")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_topup_intent_payload(self) -> Dict[str, Any]:
        """Build payload for TOPUP_INTENT message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "consumer": self._serialize_value(self.load("consumer")),
            "additional_amount": self._serialize_value(self.load("additional_amount")),
            "current_lock_result_hash": self._serialize_value(self.load("current_lock_result_hash")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_liveness_pong_payload(self) -> Dict[str, Any]:
        """Build payload for LIVENESS_PONG message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "from_witness": self._serialize_value(self.load("from_witness")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_witness_request_payload(self) -> Dict[str, Any]:
        """Build payload for WITNESS_REQUEST message."""
        payload = {
            "consumer": self._serialize_value(self.load("consumer")),
            "provider": self._serialize_value(self.load("provider")),
            "amount": self._serialize_value(self.load("amount")),
            "session_id": self._serialize_value(self.load("session_id")),
            "my_chain_head": self._serialize_value(self.load("my_chain_head")),
            "witnesses": self._serialize_value(self.load("witnesses")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_consumer_signed_topup_payload(self) -> Dict[str, Any]:
        """Build payload for CONSUMER_SIGNED_TOPUP message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "consumer_signature": self._serialize_value(self.load("consumer_signature")),
            "timestamp": self.current_time,
        }
        return payload

    def _check_provider_chain_checkpoint_neq_null(self) -> bool:
        # Schema: provider_chain_checkpoint != null...
        return self.load("provider_chain_checkpoint") != None

    def _check_chain_segment_valid_and_contains_checkpoint(self) -> bool:
        # Schema: chain_segment_valid_and_contains_checkpoint...
        return self.load("chain_segment_valid_and_contains_checkpoint")

    def _check_witness_selection_valid(self) -> bool:
        # Schema: witness_selection_valid...
        return self.load("witness_selection_valid")

    def _check_result_valid_and_accepted(self) -> bool:
        # Schema: result_valid_and_accepted...
        return self.load("result_valid_and_accepted")

    def _check_NOT_result_valid_and_accepted(self) -> bool:
        # Schema: NOT result_valid_and_accepted...
        return not self.load("result_valid_and_accepted")

    def _check_topup_result_valid(self) -> bool:
        # Schema: topup_result_valid...
        return self.load("topup_result_valid")

    def _compute_session_id(self) -> Any:
        """Compute session_id."""
        # Schema: HASH(peer_id + provider + NOW())...
        return hash_data(self._to_hashable(self.peer_id, self.load("provider"), self.current_time))

    def _compute_consumer_nonce(self) -> Any:
        """Compute consumer_nonce."""
        # Schema: RANDOM_BYTES(32)...
        return random_bytes(32)

    def _compute_provider_chain_checkpoint(self) -> Any:
        """Compute provider_chain_checkpoint."""
        # Schema: READ(provider, "head_hash")...
        return self._read_chain(self.load("provider"), "head_hash")

    def _compute_chain_segment_valid_and_contains_checkpoint(self) -> Any:
        """Compute chain_segment_valid_and_contains_checkpoint."""
        # Schema: VERIFY_CHAIN_SEGMENT(provider_chain_segment)  and CHAIN_CONT...
        return self._verify_chain_segment(self.load("provider_chain_segment")) and self._chain_contains_hash(self.load("provider_chain_segment"), self.load("provider_chain_checkpoint"))

    def _compute_verified_chain_state(self) -> Any:
        """Compute verified_chain_state."""
        # Schema: CHAIN_STATE_AT(provider_chain_segment, provider_chain_checkp...
        return self._chain_state_at(self.load("provider_chain_segment"), self.load("provider_chain_checkpoint"))

    def _compute_witness_selection_valid(self) -> Any:
        """Compute witness_selection_valid."""
        # Schema: VERIFY_WITNESS_SELECTION(proposed_witnesses, selection_input...
        return self._VERIFY_WITNESS_SELECTION(self.load("proposed_witnesses"), self.load("selection_inputs"), self.load("session_id"), self.load("provider_nonce"), self.load("consumer_nonce"))

    def _compute_result_valid_and_accepted(self) -> Any:
        """Compute result_valid_and_accepted."""
        # Schema: VALIDATE_LOCK_RESULT(pending_result, session_id, amount)...
        return self._VALIDATE_LOCK_RESULT(self.load("pending_result"), self.load("session_id"), self.load("amount"))

    def _compute_consumer_signature(self) -> Any:
        """Compute consumer_signature."""
        # Schema: SIGN(pending_result)...
        return sign(self.chain.private_key, hash_data(self.load("pending_result")))

    def _compute_current_lock_hash(self) -> Any:
        """Compute current_lock_hash."""
        # Schema: HASH(lock_result)...
        return hash_data(self._to_hashable(self.load("lock_result")))

    def _compute_topup_result_valid(self) -> Any:
        """Compute topup_result_valid."""
        # Schema: VALIDATE_TOPUP_RESULT(pending_topup_result, session_id, addi...
        return self._VALIDATE_TOPUP_RESULT(self.load("pending_topup_result"), self.load("session_id"), self.load("additional_amount"))

    def _build_balance_lock_payload(self) -> Dict[str, Any]:
        """Build payload for BALANCE_LOCK chain block."""
        return {
            "session_id": self.load("session_id"),
            "amount": self.load("amount"),
            "lock_result_hash": self.load("lock_result_hash"),
            "timestamp": self.current_time,
        }

    def _build_balance_topup_payload(self) -> Dict[str, Any]:
        """Build payload for BALANCE_TOPUP chain block."""
        return {
            "session_id": self.load("session_id"),
            "previous_total": self.load("previous_total"),
            "topup_amount": self.load("topup_amount"),
            "new_total": self.load("new_total"),
            "topup_result_hash": self.load("topup_result_hash"),
            "timestamp": self.current_time,
        }

    def _read_chain(self, chain: Any, query: str) -> Any:
        """READ: Read from a chain (own or cached peer chain)."""
        if chain == 'my_chain' or chain is self.chain:
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
        if chain == 'my_chain' or chain is self.chain:
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
        accept_count = len ([v for v in verdicts if v == WitnessVerdict.ACCEPT])
        if accept_count >= threshold:
            return "ACCEPT"
        else:
            return "REJECT"

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        return [r.get(field) for r in records]

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        return len (self._FILTER (items, predicate))

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        return len ([x for x in items if x == item]) > 0

    def _REMOVE(self, items: List[Any], item: Any) -> List[Any]:
        """Compute REMOVE."""
        return [x for x in items if x != item]

    def _SET_EQUALS(self, a: List[Any], b: List[Any]) -> bool:
        """Compute SET_EQUALS."""
        a_not_in_b = len ([x for x in a if not self._CONTAINS (b, x)])
        b_not_in_a = len ([x for x in b if not self._CONTAINS (a, x)])
        return a_not_in_b == 0 and b_not_in_a == 0

    def _MIN(self, a: int, b: int) -> int:
        """Compute MIN."""
        return (a if a < b else b)

    def _MAX(self, a: int, b: int) -> int:
        """Compute MAX."""
        return (a if a > b else b)

    def _GET(self, d: Dict[str, Any], key: str, default: Any) -> Any:
        """Compute GET."""
        return (d.get(key) if self._has_key (d, key) else default)

    def _COMPUTE_ESCROW_CONSENSUS(self, preliminaries: List[Dict[str, Any]]) -> str:
        """Compute COMPUTE_ESCROW_CONSENSUS."""
        my_verdict = self.load("verdict")
        accept_count = (1 if my_verdict == "ACCEPT" else 0)
        for p in preliminaries:
            accept_count = (accept_count + 1 if p.get("verdict")== "ACCEPT" else accept_count)
        return ("ACCEPT" if accept_count >= WITNESS_THRESHOLD else "REJECT")

    def _BUILD_LOCK_RESULT(self) -> str:
        """Compute BUILD_LOCK_RESULT."""
        consensus = self.load("consensus_direction")
        status = (LockStatus.ACCEPTED if consensus == "ACCEPT" else LockStatus.REJECTED)
        votes = self.load("votes")
        signatures = [v.get("signature") for v in votes]
        return {"session_id": self.load("session_id"), "consumer": self.load("consumer"), "provider": self.load("provider"), "amount": self.load("amount"), "status": status, "observed_balance": self.load("observed_balance"), "witnesses": self.load("witnesses"), "witness_signatures": signatures, "consumer_signature": None, "timestamp": self.current_time}

    def _BUILD_TOPUP_RESULT(self) -> str:
        """Compute BUILD_TOPUP_RESULT."""
        consensus = self.load("topup_consensus_direction")
        status = (LockStatus.ACCEPTED if consensus == "ACCEPT" else LockStatus.REJECTED)
        votes = self.load("topup_votes")
        signatures = [v.get("signature") for v in votes]
        return {"session_id": self.load("session_id"), "consumer": self.load("consumer"), "provider": self.load("provider"), "previous_total": self.load("total_escrowed"), "additional_amount": self.load("topup_intent").get("additional_amount"), "new_total": self.load("total_escrowed") + self.load("topup_intent").get("additional_amount"), "observed_balance": self.load("topup_observed_balance"), "witnesses": self.load("witnesses"), "witness_signatures": signatures, "consumer_signature": None, "timestamp": self.current_time}

    def _VALIDATE_LOCK_RESULT(self, result: Dict[str, Any], expected_session_id: str, expected_amount: int) -> bool:
        """Compute VALIDATE_LOCK_RESULT."""
        valid_session = result != None and result.get("session_id")== expected_session_id
        valid_amount = result != None and result.get("amount")== expected_amount
        valid_status = result != None and (result.get("status")== LockStatus.ACCEPTED or result.get("status")== "ACCEPTED")
        has_sigs = result != None and len (result.get("witness_signatures")) > 0
        return valid_session and valid_amount and valid_status and has_sigs

    def _VALIDATE_TOPUP_RESULT(self, result: Dict[str, Any], expected_session_id: str, expected_additional_amount: int) -> bool:
        """Compute VALIDATE_TOPUP_RESULT."""
        valid_session = result != None and result.get("session_id")== expected_session_id
        valid_amount = result != None and result.get("additional_amount")== expected_additional_amount
        has_sigs = result != None and len (result.get("witness_signatures")) > 0
        return valid_session and valid_amount and has_sigs

    def _VERIFY_WITNESS_SELECTION(self, proposed_witnesses: List[str], chain_state: Dict[str, Any], session_id: str, provider_nonce: bytes, consumer_nonce: bytes) -> bool:
        """Compute VERIFY_WITNESS_SELECTION."""
        seed = hash_data(self._to_hashable(session_id, provider_nonce, consumer_nonce))
        expected = self._SELECT_WITNESSES (seed, chain_state)
        return self._SET_EQUALS (proposed_witnesses, expected)

    def _SELECT_WITNESSES(self, seed: bytes, chain_state: Dict[str, Any]) -> List[str]:
        """Compute SELECT_WITNESSES."""
        known_peers = chain_state.get("known_peers")
        consumer = self.load("consumer")
        provider = self.load("provider")
        candidates = [p for p in known_peers if p != self.peer_id and p != consumer and p != provider]
        candidates = self._sort (candidates)
        trust_scores = chain_state.get("trust_scores")
        high_trust = [c for c in candidates if self._GET (trust_scores, c, 0) >= HIGH_TRUST_THRESHOLD]
        low_trust = [c for c in candidates if self._GET (trust_scores, c, 0) < HIGH_TRUST_THRESHOLD]
        rng = self._seeded_rng (seed)
        selected = []
        ht_sample = self._MIN (MIN_HIGH_TRUST_WITNESSES, len (high_trust))
        selected = self._seeded_sample (rng, high_trust, ht_sample)
        remaining = [c for c in candidates if not self._CONTAINS (selected, c)]
        needed = WITNESS_COUNT - len (selected)
        additional = self._seeded_sample (rng, remaining, needed)
        return self._concat (selected, additional)

# =============================================================================
# Provider
# =============================================================================

class ProviderState(Enum):
    """Provider states."""
    IDLE = auto()  # Waiting for lock request
    VALIDATING_CHECKPOINT = auto()  # Validating consumer's checkpoint reference
    SENDING_REJECTION = auto()  # Sending rejection due to invalid checkpoint
    SELECTING_WITNESSES = auto()  # Computing deterministic witness selection
    SENDING_COMMITMENT = auto()  # Sending witness selection to consumer
    WAITING_FOR_LOCK = auto()  # Waiting for lock to complete
    SERVICE_PHASE = auto()  # Lock complete, providing service

@dataclass
class Provider(Actor):
    """Party providing service, selects witnesses"""

    state: ProviderState = ProviderState.IDLE

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ProviderState.IDLE:
            # Check for LOCK_INTENT
            msgs = self.get_messages(MessageType.LOCK_INTENT)
            if msgs:
                msg = msgs[0]
                self.store("consumer", msg.payload.get("consumer"))
                self.store("amount", msg.payload.get("amount"))
                self.store("session_id", msg.payload.get("session_id"))
                self.store("consumer_nonce", msg.payload.get("consumer_nonce"))
                self.store("requested_checkpoint", msg.payload.get("provider_chain_checkpoint"))
                # Compute: provider_nonce = RANDOM_BYTES(32)
                self.store("provider_nonce", self._compute_provider_nonce())
                self.transition_to(ProviderState.VALIDATING_CHECKPOINT)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == ProviderState.VALIDATING_CHECKPOINT:
            # Auto transition with guard: CHAIN_CONTAINS_HASH (my_chain, requested_checkpoint)
            if self._check_CHAIN_CONTAINS_HASH_my_chain_requested_checkpoint():
                # Compute: chain_state_at_checkpoint = CHAIN_STATE_AT(my_chain, requested_checkpoint)
                self.store("chain_state_at_checkpoint", self._compute_chain_state_at_checkpoint())
                # Compute: provider_chain_segment = CHAIN_SEGMENT(my_chain, requested_checkpoint)
                self.store("provider_chain_segment", self._compute_provider_chain_segment())
                self.transition_to(ProviderState.SELECTING_WITNESSES)
            else:
                self.store("reason", 'unknown_checkpoint')
                self.transition_to(ProviderState.SENDING_REJECTION)

        elif self.state == ProviderState.SENDING_REJECTION:
            # Auto transition
            msg_payload = self._build_lock_rejected_payload()
            outgoing.append(Message(
                msg_type=MessageType.LOCK_REJECTED,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("consumer"),
            ))
            self.transition_to(ProviderState.IDLE)

        elif self.state == ProviderState.SELECTING_WITNESSES:
            # Auto transition
            # Compute: witnesses = SELECT_WITNESSES(HASH(session_id + provider_nonce + consumer_nonce), chain_state_at_checkpoint)
            self.store("witnesses", self._compute_witnesses())
            self.store("selection_inputs", self.load("chain_state_at_checkpoint"))
            self.transition_to(ProviderState.SENDING_COMMITMENT)

        elif self.state == ProviderState.SENDING_COMMITMENT:
            # Auto transition
            msg_payload = self._build_witness_selection_commitment_payload()
            outgoing.append(Message(
                msg_type=MessageType.WITNESS_SELECTION_COMMITMENT,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("consumer"),
            ))
            self.store("commitment_sent_at", self.current_time)
            self.transition_to(ProviderState.WAITING_FOR_LOCK)

        elif self.state == ProviderState.WAITING_FOR_LOCK:
            # Check for BALANCE_UPDATE_BROADCAST
            msgs = self.get_messages(MessageType.BALANCE_UPDATE_BROADCAST)
            if msgs:
                msg = msgs[0]
                self.store("lock_result", msg.payload.get("lock_result"))
                self.transition_to(ProviderState.SERVICE_PHASE)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > LOCK_TIMEOUT:
                self.store("session_id", None)
                self.transition_to(ProviderState.IDLE)


        elif self.state == ProviderState.SERVICE_PHASE:
            # Lock complete, providing service
            pass

        return outgoing

    def _build_lock_rejected_payload(self) -> Dict[str, Any]:
        """Build payload for LOCK_REJECTED message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "reason": self._serialize_value(self.load("reason")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_witness_selection_commitment_payload(self) -> Dict[str, Any]:
        """Build payload for WITNESS_SELECTION_COMMITMENT message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "provider": self._serialize_value(self.load("provider")),
            "provider_nonce": self._serialize_value(self.load("provider_nonce")),
            "provider_chain_segment": self._serialize_value(self.load("provider_chain_segment")),
            "selection_inputs": self._serialize_value(self.load("selection_inputs")),
            "witnesses": self._serialize_value(self.load("witnesses")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _check_CHAIN_CONTAINS_HASH_my_chain_requested_checkpoint(self) -> bool:
        # Schema: CHAIN_CONTAINS_HASH (my_chain, requested_checkpoint)...
        return self._chain_contains_hash (self.chain, self.load("requested_checkpoint"))

    def _check_message_lock_result_session_id_eq_session_id_and_message_loc(self) -> bool:
        # Schema: message.lock_result.session_id == session_id and message.loc...
        return self.load("message").get("lock_result").get("session_id")== self.load("session_id") and self.load("message").get("lock_result").get("status")== LockStatus.ACCEPTED

    def _compute_provider_nonce(self) -> Any:
        """Compute provider_nonce."""
        # Schema: RANDOM_BYTES(32)...
        return random_bytes(32)

    def _compute_chain_state_at_checkpoint(self) -> Any:
        """Compute chain_state_at_checkpoint."""
        # Schema: CHAIN_STATE_AT(my_chain, requested_checkpoint)...
        return self._chain_state_at(self.chain, self.load("requested_checkpoint"))

    def _compute_provider_chain_segment(self) -> Any:
        """Compute provider_chain_segment."""
        # Schema: CHAIN_SEGMENT(my_chain, requested_checkpoint)...
        return self._chain_segment(self.chain, self.load("requested_checkpoint"))

    def _compute_witnesses(self) -> Any:
        """Compute witnesses."""
        # Schema: SELECT_WITNESSES(HASH(session_id + provider_nonce + consumer...
        return self._SELECT_WITNESSES(hash_data(self._to_hashable(self.load("session_id"), self.load("provider_nonce"), self.load("consumer_nonce"))), self.load("chain_state_at_checkpoint"))

    def _read_chain(self, chain: Any, query: str) -> Any:
        """READ: Read from a chain (own or cached peer chain)."""
        if chain == 'my_chain' or chain is self.chain:
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
        if chain == 'my_chain' or chain is self.chain:
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
        accept_count = len ([v for v in verdicts if v == WitnessVerdict.ACCEPT])
        if accept_count >= threshold:
            return "ACCEPT"
        else:
            return "REJECT"

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        return [r.get(field) for r in records]

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        return len (self._FILTER (items, predicate))

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        return len ([x for x in items if x == item]) > 0

    def _REMOVE(self, items: List[Any], item: Any) -> List[Any]:
        """Compute REMOVE."""
        return [x for x in items if x != item]

    def _SET_EQUALS(self, a: List[Any], b: List[Any]) -> bool:
        """Compute SET_EQUALS."""
        a_not_in_b = len ([x for x in a if not self._CONTAINS (b, x)])
        b_not_in_a = len ([x for x in b if not self._CONTAINS (a, x)])
        return a_not_in_b == 0 and b_not_in_a == 0

    def _MIN(self, a: int, b: int) -> int:
        """Compute MIN."""
        return (a if a < b else b)

    def _MAX(self, a: int, b: int) -> int:
        """Compute MAX."""
        return (a if a > b else b)

    def _GET(self, d: Dict[str, Any], key: str, default: Any) -> Any:
        """Compute GET."""
        return (d.get(key) if self._has_key (d, key) else default)

    def _COMPUTE_ESCROW_CONSENSUS(self, preliminaries: List[Dict[str, Any]]) -> str:
        """Compute COMPUTE_ESCROW_CONSENSUS."""
        my_verdict = self.load("verdict")
        accept_count = (1 if my_verdict == "ACCEPT" else 0)
        for p in preliminaries:
            accept_count = (accept_count + 1 if p.get("verdict")== "ACCEPT" else accept_count)
        return ("ACCEPT" if accept_count >= WITNESS_THRESHOLD else "REJECT")

    def _BUILD_LOCK_RESULT(self) -> str:
        """Compute BUILD_LOCK_RESULT."""
        consensus = self.load("consensus_direction")
        status = (LockStatus.ACCEPTED if consensus == "ACCEPT" else LockStatus.REJECTED)
        votes = self.load("votes")
        signatures = [v.get("signature") for v in votes]
        return {"session_id": self.load("session_id"), "consumer": self.load("consumer"), "provider": self.load("provider"), "amount": self.load("amount"), "status": status, "observed_balance": self.load("observed_balance"), "witnesses": self.load("witnesses"), "witness_signatures": signatures, "consumer_signature": None, "timestamp": self.current_time}

    def _BUILD_TOPUP_RESULT(self) -> str:
        """Compute BUILD_TOPUP_RESULT."""
        consensus = self.load("topup_consensus_direction")
        status = (LockStatus.ACCEPTED if consensus == "ACCEPT" else LockStatus.REJECTED)
        votes = self.load("topup_votes")
        signatures = [v.get("signature") for v in votes]
        return {"session_id": self.load("session_id"), "consumer": self.load("consumer"), "provider": self.load("provider"), "previous_total": self.load("total_escrowed"), "additional_amount": self.load("topup_intent").get("additional_amount"), "new_total": self.load("total_escrowed") + self.load("topup_intent").get("additional_amount"), "observed_balance": self.load("topup_observed_balance"), "witnesses": self.load("witnesses"), "witness_signatures": signatures, "consumer_signature": None, "timestamp": self.current_time}

    def _VALIDATE_LOCK_RESULT(self, result: Dict[str, Any], expected_session_id: str, expected_amount: int) -> bool:
        """Compute VALIDATE_LOCK_RESULT."""
        valid_session = result != None and result.get("session_id")== expected_session_id
        valid_amount = result != None and result.get("amount")== expected_amount
        valid_status = result != None and (result.get("status")== LockStatus.ACCEPTED or result.get("status")== "ACCEPTED")
        has_sigs = result != None and len (result.get("witness_signatures")) > 0
        return valid_session and valid_amount and valid_status and has_sigs

    def _VALIDATE_TOPUP_RESULT(self, result: Dict[str, Any], expected_session_id: str, expected_additional_amount: int) -> bool:
        """Compute VALIDATE_TOPUP_RESULT."""
        valid_session = result != None and result.get("session_id")== expected_session_id
        valid_amount = result != None and result.get("additional_amount")== expected_additional_amount
        has_sigs = result != None and len (result.get("witness_signatures")) > 0
        return valid_session and valid_amount and has_sigs

    def _VERIFY_WITNESS_SELECTION(self, proposed_witnesses: List[str], chain_state: Dict[str, Any], session_id: str, provider_nonce: bytes, consumer_nonce: bytes) -> bool:
        """Compute VERIFY_WITNESS_SELECTION."""
        seed = hash_data(self._to_hashable(session_id, provider_nonce, consumer_nonce))
        expected = self._SELECT_WITNESSES (seed, chain_state)
        return self._SET_EQUALS (proposed_witnesses, expected)

    def _SELECT_WITNESSES(self, seed: bytes, chain_state: Dict[str, Any]) -> List[str]:
        """Compute SELECT_WITNESSES."""
        known_peers = chain_state.get("known_peers")
        consumer = self.load("consumer")
        provider = self.load("provider")
        candidates = [p for p in known_peers if p != self.peer_id and p != consumer and p != provider]
        candidates = self._sort (candidates)
        trust_scores = chain_state.get("trust_scores")
        high_trust = [c for c in candidates if self._GET (trust_scores, c, 0) >= HIGH_TRUST_THRESHOLD]
        low_trust = [c for c in candidates if self._GET (trust_scores, c, 0) < HIGH_TRUST_THRESHOLD]
        rng = self._seeded_rng (seed)
        selected = []
        ht_sample = self._MIN (MIN_HIGH_TRUST_WITNESSES, len (high_trust))
        selected = self._seeded_sample (rng, high_trust, ht_sample)
        remaining = [c for c in candidates if not self._CONTAINS (selected, c)]
        needed = WITNESS_COUNT - len (selected)
        additional = self._seeded_sample (rng, remaining, needed)
        return self._concat (selected, additional)

# =============================================================================
# Witness
# =============================================================================

class WitnessState(Enum):
    """Witness states."""
    IDLE = auto()  # Waiting for witness request
    CHECKING_CHAIN_KNOWLEDGE = auto()  # Checking if we have recent consumer chain data
    REQUESTING_CHAIN_SYNC = auto()  # Requesting chain data from peers
    WAITING_FOR_CHAIN_SYNC = auto()  # Waiting for chain sync response
    CHECKING_BALANCE = auto()  # Verifying consumer has sufficient balance
    CHECKING_EXISTING_LOCKS = auto()  # Checking for existing locks on balance
    SHARING_PRELIMINARY = auto()  # Sharing preliminary verdict with peers
    COLLECTING_PRELIMINARIES = auto()  # Collecting preliminary verdicts
    EVALUATING_PRELIMINARIES = auto()  # Evaluating preliminary consensus
    VOTING = auto()  # Casting final vote
    COLLECTING_VOTES = auto()  # Collecting final votes
    EVALUATING_VOTES = auto()  # Evaluating vote consensus
    BUILDING_RESULT = auto()  # Building final lock result
    RECRUITING_MORE = auto()  # Recruiting additional witnesses
    WAITING_FOR_RECRUITS = auto()  # Waiting for recruit responses
    SIGNING_RESULT = auto()  # Signing the lock result
    COLLECTING_SIGNATURES = auto()  # Collecting peer signatures
    PROPAGATING_RESULT = auto()  # Sending result to consumer
    WAITING_FOR_CONSUMER_SIGNATURE = auto()  # Waiting for consumer counter-signature
    FINALIZING = auto()  # Recording lock on chain and broadcasting
    ESCROW_ACTIVE = auto()  # Escrow locked, monitoring liveness
    DONE = auto()  # Lock process complete
    REJECTED = auto()  # Witness declined to participate
    CHECKING_TOPUP_BALANCE = auto()  # Verifying consumer has additional free balance
    VOTING_TOPUP = auto()  # Voting on top-up request
    COLLECTING_TOPUP_VOTES = auto()  # Collecting top-up votes from other witnesses
    BUILDING_TOPUP_RESULT = auto()  # Building the top-up result after consensus
    PROPAGATING_TOPUP = auto()  # Sending top-up result to consumer for signature
    WAITING_FOR_CONSUMER_TOPUP_SIGNATURE = auto()  # Waiting for consumer top-up signature

@dataclass
class Witness(Actor):
    """Verifies consumer balance, participates in consensus"""

    state: WitnessState = WitnessState.IDLE

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == WitnessState.IDLE:
            # Check for WITNESS_REQUEST
            msgs = self.get_messages(MessageType.WITNESS_REQUEST)
            if msgs:
                msg = msgs[0]
                self.store("consumer", msg.payload.get("consumer"))
                self.store("provider", msg.payload.get("provider"))
                self.store("amount", msg.payload.get("amount"))
                self.store("session_id", msg.payload.get("session_id"))
                self.store("my_chain_head", msg.payload.get("my_chain_head"))
                self.store("witnesses", msg.payload.get("witnesses"))
                self.store("consumer", msg.sender)
                # Compute: other_witnesses = REMOVE(witnesses, peer_id)
                self.store("other_witnesses", self._compute_other_witnesses())
                self.store("preliminaries", [])
                self.store("votes", [])
                self.store("signatures", [])
                self.store("recruitment_round", '0')
                self.transition_to(WitnessState.CHECKING_CHAIN_KNOWLEDGE)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == WitnessState.CHECKING_CHAIN_KNOWLEDGE:
            # Auto transition
            # Compute: observed_balance = peer_balances[consumer]
            self.store("observed_balance", self._compute_observed_balance())
            self.transition_to(WitnessState.CHECKING_BALANCE)

        elif self.state == WitnessState.REQUESTING_CHAIN_SYNC:
            # Requesting chain data from peers
            pass

        elif self.state == WitnessState.WAITING_FOR_CHAIN_SYNC:
            # Waiting for chain sync response
            pass

        elif self.state == WitnessState.CHECKING_BALANCE:
            # Auto transition with guard: observed_balance >= amount
            if self._check_observed_balance_gte_amount():
                self.transition_to(WitnessState.CHECKING_EXISTING_LOCKS)
            # Auto transition with guard: observed_balance < amount
            elif self._check_observed_balance_lt_amount():
                self.store("verdict", WitnessVerdict.REJECT)
                self.store("reject_reason", 'insufficient_balance')
                self.transition_to(WitnessState.SHARING_PRELIMINARY)

        elif self.state == WitnessState.CHECKING_EXISTING_LOCKS:
            # Auto transition
            self.store("verdict", WitnessVerdict.ACCEPT)
            self.transition_to(WitnessState.SHARING_PRELIMINARY)

        elif self.state == WitnessState.SHARING_PRELIMINARY:
            # Auto transition
            for recipient in self.load("other_witnesses", []):
                msg_payload = self._build_witness_preliminary_payload()
                outgoing.append(Message(
                    msg_type=MessageType.WITNESS_PRELIMINARY,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.store("preliminary_sent_at", self.current_time)
            self.transition_to(WitnessState.COLLECTING_PRELIMINARIES)

        elif self.state == WitnessState.COLLECTING_PRELIMINARIES:
            # Check for WITNESS_PRELIMINARY
            msgs = self.get_messages(MessageType.WITNESS_PRELIMINARY)
            if msgs:
                msg = msgs[0]
                _list = self.load("preliminaries") or []
                _list.append(msg.payload)
                self.store("preliminaries", _list)
                self.transition_to(WitnessState.COLLECTING_PRELIMINARIES)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > PRELIMINARY_TIMEOUT:
                # Compute: consensus_direction = COMPUTE_ESCROW_CONSENSUS(preliminaries)
                self.store("consensus_direction", self._compute_consensus_direction())
                self.transition_to(WitnessState.VOTING)

            # Auto transition with guard: LENGTH (preliminaries) >= WITNESS_THRESHOLD - 1
            if self._check_LENGTH_preliminaries_gte_WITNESS_THRESHOLD_1():
                # Compute: consensus_direction = COMPUTE_ESCROW_CONSENSUS(preliminaries)
                self.store("consensus_direction", self._compute_consensus_direction())
                self.transition_to(WitnessState.VOTING)

        elif self.state == WitnessState.EVALUATING_PRELIMINARIES:
            # Evaluating preliminary consensus
            pass

        elif self.state == WitnessState.VOTING:
            # Auto transition
            for recipient in self.load("other_witnesses", []):
                msg_payload = self._build_witness_final_vote_payload()
                outgoing.append(Message(
                    msg_type=MessageType.WITNESS_FINAL_VOTE,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.transition_to(WitnessState.COLLECTING_VOTES)

        elif self.state == WitnessState.COLLECTING_VOTES:
            # Check for WITNESS_FINAL_VOTE
            msgs = self.get_messages(MessageType.WITNESS_FINAL_VOTE)
            if msgs:
                msg = msgs[0]
                _list = self.load("votes") or []
                _list.append(msg.payload)
                self.store("votes", _list)
                self.transition_to(WitnessState.COLLECTING_VOTES)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONSENSUS_TIMEOUT:
                self.transition_to(WitnessState.BUILDING_RESULT)

            # Auto transition with guard: LENGTH (votes) >= WITNESS_THRESHOLD
            if self._check_LENGTH_votes_gte_WITNESS_THRESHOLD():
                self.transition_to(WitnessState.BUILDING_RESULT)

        elif self.state == WitnessState.EVALUATING_VOTES:
            # Evaluating vote consensus
            pass

        elif self.state == WitnessState.BUILDING_RESULT:
            # Auto transition
            # Compute: result = BUILD_LOCK_RESULT()
            self.store("result", self._compute_result())
            self.transition_to(WitnessState.SIGNING_RESULT)

        elif self.state == WitnessState.RECRUITING_MORE:
            # Recruiting additional witnesses
            pass

        elif self.state == WitnessState.WAITING_FOR_RECRUITS:
            # Waiting for recruit responses
            pass

        elif self.state == WitnessState.SIGNING_RESULT:
            # Auto transition
            msg_payload = self._build_lock_result_for_signature_payload()
            outgoing.append(Message(
                msg_type=MessageType.LOCK_RESULT_FOR_SIGNATURE,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("consumer"),
            ))
            self.store("propagated_at", self.current_time)
            self.transition_to(WitnessState.PROPAGATING_RESULT)

        elif self.state == WitnessState.COLLECTING_SIGNATURES:
            # Collecting peer signatures
            pass

        elif self.state == WitnessState.PROPAGATING_RESULT:
            # Check for CONSUMER_SIGNED_LOCK
            msgs = self.get_messages(MessageType.CONSUMER_SIGNED_LOCK)
            if msgs:
                msg = msgs[0]
                self.store("consumer_signature", msg.payload.get("signature"))
                self.store("total_escrowed", self.load("amount"))
                self.chain.append(
                    BlockType.WITNESS_COMMITMENT,
                    self._build_witness_commitment_payload(),
                    current_time,
                )
                msg_payload = self._build_balance_update_broadcast_payload()
                outgoing.append(Message(
                    msg_type=MessageType.BALANCE_UPDATE_BROADCAST,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=self.load("provider"),
                ))
                self.transition_to(WitnessState.ESCROW_ACTIVE)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONSENSUS_TIMEOUT:
                self.store("reject_reason", 'consumer_signature_timeout')
                self.transition_to(WitnessState.DONE)


        elif self.state == WitnessState.WAITING_FOR_CONSUMER_SIGNATURE:
            # Waiting for consumer counter-signature
            pass

        elif self.state == WitnessState.FINALIZING:
            # Recording lock on chain and broadcasting
            pass

        elif self.state == WitnessState.ESCROW_ACTIVE:
            # Check for TOPUP_INTENT
            msgs = self.get_messages(MessageType.TOPUP_INTENT)
            if msgs:
                msg = msgs[0]
                self.store("topup_intent", msg.payload)
                # Compute: topup_observed_balance = peer_balances[consumer]
                self.store("topup_observed_balance", self._compute_topup_observed_balance())
                self.transition_to(WitnessState.CHECKING_TOPUP_BALANCE)
                self.message_queue.remove(msg)  # Only remove processed message

            # Check for LIVENESS_PING
            msgs = self.get_messages(MessageType.LIVENESS_PING)
            if msgs:
                msg = msgs[0]
                self.store("from_witness", self.peer_id)
                msg_payload = self._build_liveness_pong_payload()
                outgoing.append(Message(
                    msg_type=MessageType.LIVENESS_PONG,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=msg.sender,
                ))
                self.transition_to(WitnessState.ESCROW_ACTIVE)
                self.message_queue.remove(msg)  # Only remove processed message


        elif self.state == WitnessState.DONE:
            # Lock process complete
            pass

        elif self.state == WitnessState.REJECTED:
            # Witness declined to participate
            pass

        elif self.state == WitnessState.CHECKING_TOPUP_BALANCE:
            # Auto transition with guard: topup_observed_balance - total_escrowed >= topup_intent.additional_amount
            if self._check_topup_observed_balance_total_escrowed_gte_topup_intent_addit():
                self.store("topup_verdict", 'accept')
                self.transition_to(WitnessState.VOTING_TOPUP)
            # Auto transition with guard: topup_observed_balance - total_escrowed < topup_intent.additional_amount
            elif self._check_topup_observed_balance_total_escrowed_lt_topup_intent_additi():
                self.store("topup_verdict", 'reject')
                self.store("topup_reject_reason", 'insufficient_free_balance')
                self.transition_to(WitnessState.ESCROW_ACTIVE)

        elif self.state == WitnessState.VOTING_TOPUP:
            # Auto transition
            self.store("topup_votes", [])
            for recipient in self.load("other_witnesses", []):
                msg_payload = self._build_topup_vote_payload()
                outgoing.append(Message(
                    msg_type=MessageType.TOPUP_VOTE,
                    sender=self.peer_id,
                    payload=msg_payload,
                    timestamp=current_time,
                    recipient=recipient,
                ))
            self.transition_to(WitnessState.COLLECTING_TOPUP_VOTES)

        elif self.state == WitnessState.COLLECTING_TOPUP_VOTES:
            # Check for TOPUP_VOTE
            msgs = self.get_messages(MessageType.TOPUP_VOTE)
            if msgs:
                msg = msgs[0]
                _list = self.load("topup_votes") or []
                _list.append(msg.payload)
                self.store("topup_votes", _list)
                self.transition_to(WitnessState.COLLECTING_TOPUP_VOTES)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > PRELIMINARY_TIMEOUT:
                self.transition_to(WitnessState.BUILDING_TOPUP_RESULT)

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONSENSUS_TIMEOUT:
                self.store("topup_failed_reason", 'vote_timeout')
                self.transition_to(WitnessState.ESCROW_ACTIVE)

            # Auto transition with guard: LENGTH (topup_votes) >= WITNESS_THRESHOLD - 1
            if self._check_LENGTH_topup_votes_gte_WITNESS_THRESHOLD_1():
                self.transition_to(WitnessState.BUILDING_TOPUP_RESULT)

        elif self.state == WitnessState.BUILDING_TOPUP_RESULT:
            # Auto transition
            # Compute: topup_result = BUILD_TOPUP_RESULT()
            self.store("topup_result", self._compute_topup_result())
            msg_payload = self._build_topup_result_for_signature_payload()
            outgoing.append(Message(
                msg_type=MessageType.TOPUP_RESULT_FOR_SIGNATURE,
                sender=self.peer_id,
                payload=msg_payload,
                timestamp=current_time,
                recipient=self.load("consumer"),
            ))
            self.transition_to(WitnessState.PROPAGATING_TOPUP)

        elif self.state == WitnessState.PROPAGATING_TOPUP:
            # Check for CONSUMER_SIGNED_TOPUP
            msgs = self.get_messages(MessageType.CONSUMER_SIGNED_TOPUP)
            if msgs:
                msg = msgs[0]
                self.store("total_escrowed", self.load("total_escrowed") + self.load("topup_intent").get("additional_amount"))
                self.transition_to(WitnessState.ESCROW_ACTIVE)
                self.message_queue.remove(msg)  # Only remove processed message

            # Timeout check
            if self.current_time - self.load('state_entered_at', 0) > CONSENSUS_TIMEOUT:
                self.store("topup_failed_reason", 'consumer_signature_timeout')
                self.transition_to(WitnessState.ESCROW_ACTIVE)


        elif self.state == WitnessState.WAITING_FOR_CONSUMER_TOPUP_SIGNATURE:
            # Waiting for consumer top-up signature
            pass

        return outgoing

    def _build_topup_result_for_signature_payload(self) -> Dict[str, Any]:
        """Build payload for TOPUP_RESULT_FOR_SIGNATURE message."""
        payload = {
            "topup_result": self._serialize_value(self.load("topup_result")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_lock_result_for_signature_payload(self) -> Dict[str, Any]:
        """Build payload for LOCK_RESULT_FOR_SIGNATURE message."""
        payload = {
            "result": self._serialize_value(self.load("result")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_topup_vote_payload(self) -> Dict[str, Any]:
        """Build payload for TOPUP_VOTE message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "witness": self._serialize_value(self.load("witness")),
            "vote": self._serialize_value(self.load("vote")),
            "additional_amount": self._serialize_value(self.load("additional_amount")),
            "observed_balance": self._serialize_value(self.load("observed_balance")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_balance_update_broadcast_payload(self) -> Dict[str, Any]:
        """Build payload for BALANCE_UPDATE_BROADCAST message."""
        payload = {
            "consumer": self._serialize_value(self.load("consumer")),
            "lock_result": self._serialize_value(self.load("lock_result")),
            "timestamp": self.current_time,
        }
        return payload

    def _build_witness_final_vote_payload(self) -> Dict[str, Any]:
        """Build payload for WITNESS_FINAL_VOTE message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "witness": self._serialize_value(self.load("witness")),
            "vote": self._serialize_value(self.load("vote")),
            "observed_balance": self._serialize_value(self.load("observed_balance")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_witness_preliminary_payload(self) -> Dict[str, Any]:
        """Build payload for WITNESS_PRELIMINARY message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "witness": self._serialize_value(self.load("witness")),
            "verdict": self._serialize_value(self.load("verdict")),
            "observed_balance": self._serialize_value(self.load("observed_balance")),
            "observed_chain_head": self._serialize_value(self.load("observed_chain_head")),
            "reject_reason": self._serialize_value(self.load("reject_reason")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _build_liveness_pong_payload(self) -> Dict[str, Any]:
        """Build payload for LIVENESS_PONG message."""
        payload = {
            "session_id": self._serialize_value(self.load("session_id")),
            "from_witness": self._serialize_value(self.load("from_witness")),
            "timestamp": self.current_time,
        }
        payload["signature"] = sign(self.chain.private_key, hash_data(payload))
        return payload

    def _check_observed_balance_gte_amount(self) -> bool:
        # Schema: observed_balance >= amount...
        return self.load("observed_balance") >= self.load("amount")

    def _check_observed_balance_lt_amount(self) -> bool:
        # Schema: observed_balance < amount...
        return self.load("observed_balance") < self.load("amount")

    def _check_LENGTH_preliminaries_gte_WITNESS_THRESHOLD_1(self) -> bool:
        # Schema: LENGTH (preliminaries) >= WITNESS_THRESHOLD - 1...
        return len (self.load("preliminaries")) >= WITNESS_THRESHOLD - 1

    def _check_LENGTH_votes_gte_WITNESS_THRESHOLD(self) -> bool:
        # Schema: LENGTH (votes) >= WITNESS_THRESHOLD...
        return len (self.load("votes")) >= WITNESS_THRESHOLD

    def _check_topup_observed_balance_total_escrowed_gte_topup_intent_addit(self) -> bool:
        # Schema: topup_observed_balance - total_escrowed >= topup_intent.addi...
        return self.load("topup_observed_balance") - self.load("total_escrowed") >= self.load("topup_intent").get("additional_amount")

    def _check_topup_observed_balance_total_escrowed_lt_topup_intent_additi(self) -> bool:
        # Schema: topup_observed_balance - total_escrowed < topup_intent.addit...
        return self.load("topup_observed_balance") - self.load("total_escrowed") < self.load("topup_intent").get("additional_amount")

    def _check_LENGTH_topup_votes_gte_WITNESS_THRESHOLD_1(self) -> bool:
        # Schema: LENGTH (topup_votes) >= WITNESS_THRESHOLD - 1...
        return len (self.load("topup_votes")) >= WITNESS_THRESHOLD - 1

    def _compute_other_witnesses(self) -> Any:
        """Compute other_witnesses."""
        # Schema: REMOVE(witnesses, peer_id)...
        return self._REMOVE(self.load("witnesses"), self.peer_id)

    def _compute_observed_balance(self) -> Any:
        """Compute observed_balance."""
        # Schema: peer_balances[consumer]...
        return self.load("peer_balances")[self.load("consumer")]

    def _compute_consensus_direction(self) -> Any:
        """Compute consensus_direction."""
        # Schema: COMPUTE_ESCROW_CONSENSUS(preliminaries)...
        return self._COMPUTE_ESCROW_CONSENSUS(self.load("preliminaries"))

    def _compute_result(self) -> Any:
        """Compute result."""
        # Schema: BUILD_LOCK_RESULT()...
        return self._BUILD_LOCK_RESULT()

    def _compute_topup_observed_balance(self) -> Any:
        """Compute topup_observed_balance."""
        # Schema: peer_balances[consumer]...
        return self.load("peer_balances")[self.load("consumer")]

    def _compute_topup_result(self) -> Any:
        """Compute topup_result."""
        # Schema: BUILD_TOPUP_RESULT()...
        return self._BUILD_TOPUP_RESULT()

    def _build_witness_commitment_payload(self) -> Dict[str, Any]:
        """Build payload for WITNESS_COMMITMENT chain block."""
        return {
            "session_id": self.load("session_id"),
            "consumer": self.load("consumer"),
            "provider": self.load("provider"),
            "amount": self.load("amount"),
            "observed_balance": self.load("observed_balance"),
            "witnesses": self.load("witnesses"),
            "timestamp": self.current_time,
        }

    def _read_chain(self, chain: Any, query: str) -> Any:
        """READ: Read from a chain (own or cached peer chain)."""
        if chain == 'my_chain' or chain is self.chain:
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
        if chain == 'my_chain' or chain is self.chain:
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
        accept_count = len ([v for v in verdicts if v == WitnessVerdict.ACCEPT])
        if accept_count >= threshold:
            return "ACCEPT"
        else:
            return "REJECT"

    def _EXTRACT_FIELD(self, records: List[Any], field: str) -> List[Any]:
        """Compute EXTRACT_FIELD."""
        return [r.get(field) for r in records]

    def _COUNT_MATCHING(self, items: List[Any], predicate: Any) -> int:
        """Compute COUNT_MATCHING."""
        return len (self._FILTER (items, predicate))

    def _CONTAINS(self, items: List[Any], item: Any) -> bool:
        """Compute CONTAINS."""
        return len ([x for x in items if x == item]) > 0

    def _REMOVE(self, items: List[Any], item: Any) -> List[Any]:
        """Compute REMOVE."""
        return [x for x in items if x != item]

    def _SET_EQUALS(self, a: List[Any], b: List[Any]) -> bool:
        """Compute SET_EQUALS."""
        a_not_in_b = len ([x for x in a if not self._CONTAINS (b, x)])
        b_not_in_a = len ([x for x in b if not self._CONTAINS (a, x)])
        return a_not_in_b == 0 and b_not_in_a == 0

    def _MIN(self, a: int, b: int) -> int:
        """Compute MIN."""
        return (a if a < b else b)

    def _MAX(self, a: int, b: int) -> int:
        """Compute MAX."""
        return (a if a > b else b)

    def _GET(self, d: Dict[str, Any], key: str, default: Any) -> Any:
        """Compute GET."""
        return (d.get(key) if self._has_key (d, key) else default)

    def _COMPUTE_ESCROW_CONSENSUS(self, preliminaries: List[Dict[str, Any]]) -> str:
        """Compute COMPUTE_ESCROW_CONSENSUS."""
        my_verdict = self.load("verdict")
        accept_count = (1 if my_verdict == "ACCEPT" else 0)
        for p in preliminaries:
            accept_count = (accept_count + 1 if p.get("verdict")== "ACCEPT" else accept_count)
        return ("ACCEPT" if accept_count >= WITNESS_THRESHOLD else "REJECT")

    def _BUILD_LOCK_RESULT(self) -> str:
        """Compute BUILD_LOCK_RESULT."""
        consensus = self.load("consensus_direction")
        status = (LockStatus.ACCEPTED if consensus == "ACCEPT" else LockStatus.REJECTED)
        votes = self.load("votes")
        signatures = [v.get("signature") for v in votes]
        return {"session_id": self.load("session_id"), "consumer": self.load("consumer"), "provider": self.load("provider"), "amount": self.load("amount"), "status": status, "observed_balance": self.load("observed_balance"), "witnesses": self.load("witnesses"), "witness_signatures": signatures, "consumer_signature": None, "timestamp": self.current_time}

    def _BUILD_TOPUP_RESULT(self) -> str:
        """Compute BUILD_TOPUP_RESULT."""
        consensus = self.load("topup_consensus_direction")
        status = (LockStatus.ACCEPTED if consensus == "ACCEPT" else LockStatus.REJECTED)
        votes = self.load("topup_votes")
        signatures = [v.get("signature") for v in votes]
        return {"session_id": self.load("session_id"), "consumer": self.load("consumer"), "provider": self.load("provider"), "previous_total": self.load("total_escrowed"), "additional_amount": self.load("topup_intent").get("additional_amount"), "new_total": self.load("total_escrowed") + self.load("topup_intent").get("additional_amount"), "observed_balance": self.load("topup_observed_balance"), "witnesses": self.load("witnesses"), "witness_signatures": signatures, "consumer_signature": None, "timestamp": self.current_time}

    def _VALIDATE_LOCK_RESULT(self, result: Dict[str, Any], expected_session_id: str, expected_amount: int) -> bool:
        """Compute VALIDATE_LOCK_RESULT."""
        valid_session = result != None and result.get("session_id")== expected_session_id
        valid_amount = result != None and result.get("amount")== expected_amount
        valid_status = result != None and (result.get("status")== LockStatus.ACCEPTED or result.get("status")== "ACCEPTED")
        has_sigs = result != None and len (result.get("witness_signatures")) > 0
        return valid_session and valid_amount and valid_status and has_sigs

    def _VALIDATE_TOPUP_RESULT(self, result: Dict[str, Any], expected_session_id: str, expected_additional_amount: int) -> bool:
        """Compute VALIDATE_TOPUP_RESULT."""
        valid_session = result != None and result.get("session_id")== expected_session_id
        valid_amount = result != None and result.get("additional_amount")== expected_additional_amount
        has_sigs = result != None and len (result.get("witness_signatures")) > 0
        return valid_session and valid_amount and has_sigs

    def _VERIFY_WITNESS_SELECTION(self, proposed_witnesses: List[str], chain_state: Dict[str, Any], session_id: str, provider_nonce: bytes, consumer_nonce: bytes) -> bool:
        """Compute VERIFY_WITNESS_SELECTION."""
        seed = hash_data(self._to_hashable(session_id, provider_nonce, consumer_nonce))
        expected = self._SELECT_WITNESSES (seed, chain_state)
        return self._SET_EQUALS (proposed_witnesses, expected)

    def _SELECT_WITNESSES(self, seed: bytes, chain_state: Dict[str, Any]) -> List[str]:
        """Compute SELECT_WITNESSES."""
        known_peers = chain_state.get("known_peers")
        consumer = self.load("consumer")
        provider = self.load("provider")
        candidates = [p for p in known_peers if p != self.peer_id and p != consumer and p != provider]
        candidates = self._sort (candidates)
        trust_scores = chain_state.get("trust_scores")
        high_trust = [c for c in candidates if self._GET (trust_scores, c, 0) >= HIGH_TRUST_THRESHOLD]
        low_trust = [c for c in candidates if self._GET (trust_scores, c, 0) < HIGH_TRUST_THRESHOLD]
        rng = self._seeded_rng (seed)
        selected = []
        ht_sample = self._MIN (MIN_HIGH_TRUST_WITNESSES, len (high_trust))
        selected = self._seeded_sample (rng, high_trust, ht_sample)
        remaining = [c for c in candidates if not self._CONTAINS (selected, c)]
        needed = WITNESS_COUNT - len (selected)
        additional = self._seeded_sample (rng, remaining, needed)
        return self._concat (selected, additional)
