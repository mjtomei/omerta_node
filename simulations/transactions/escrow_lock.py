"""
Escrow Lock Transaction (Step 0)

Implements the state machines for locking funds with distributed witness consensus.

Actors:
- Consumer: party paying for service
- Provider: party providing service, selects witnesses
- Witness: verifies consumer balance, participates in consensus

See: docs/protocol/transactions/00_escrow_lock.md
"""

from enum import Enum, auto
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, Any, Callable
import time

from ..chain.primitives import (
    Chain, Block, BlockType,
    hash_data, sign, verify_sig, generate_id, random_bytes
)
from ..chain.types import (
    LockStatus, WitnessVerdict,
    LockIntent, WitnessSelectionCommitment, LockResult
)


# =============================================================================
# Parameters (from spec)
# =============================================================================

WITNESS_COUNT = 5
WITNESS_THRESHOLD = 3
WITNESS_COMMITMENT_TIMEOUT = 30.0
LOCK_TIMEOUT = 300.0
CONSENSUS_THRESHOLD = 0.67
MAX_CHAIN_AGE = 3600.0
PRELIMINARY_TIMEOUT = 30.0
CONSENSUS_TIMEOUT = 60.0
RECRUITMENT_TIMEOUT = 120.0
MAX_RECRUITMENT_ROUNDS = 3
MIN_HIGH_TRUST_WITNESSES = 2
MAX_PRIOR_INTERACTIONS = 5
CONSUMER_SIGNATURE_TIMEOUT = 60.0
LIVENESS_CHECK_INTERVAL = 300.0
LIVENESS_RESPONSE_TIMEOUT = 30.0


# =============================================================================
# Message Types
# =============================================================================

class MessageType(Enum):
    """Types of messages exchanged during escrow lock."""
    # Consumer -> Provider
    LOCK_INTENT = auto()

    # Provider -> Consumer
    WITNESS_SELECTION_COMMITMENT = auto()
    LOCK_REJECTED = auto()

    # Consumer -> Witnesses
    WITNESS_REQUEST = auto()

    # Witness <-> Witness
    WITNESS_PRELIMINARY = auto()
    WITNESS_CHAIN_SYNC_REQUEST = auto()
    WITNESS_CHAIN_SYNC_RESPONSE = auto()
    WITNESS_FINAL_VOTE = auto()
    WITNESS_RECRUIT_REQUEST = auto()

    # Witness -> Consumer
    LOCK_RESULT_FOR_SIGNATURE = auto()

    # Consumer -> Witnesses
    CONSUMER_SIGNED_LOCK = auto()

    # Witness -> Network
    BALANCE_UPDATE_BROADCAST = auto()

    # Liveness
    LIVENESS_PING = auto()
    LIVENESS_PONG = auto()

    # Top-up messages (mid-session additional funding)
    TOPUP_INTENT = auto()                      # Consumer -> Witnesses
    TOPUP_RESULT_FOR_SIGNATURE = auto()        # Witness -> Consumer
    CONSUMER_SIGNED_TOPUP = auto()             # Consumer -> Witnesses
    TOPUP_VOTE = auto()                        # Witness <-> Witness


@dataclass
class Message:
    """A message between actors."""
    msg_type: MessageType
    sender: str
    payload: dict
    timestamp: float


# =============================================================================
# State Machine Base
# =============================================================================

class ActorState(Enum):
    """Base class for actor states - subclasses define specific states."""
    pass


@dataclass
class Actor:
    """
    Base class for state machine actors.

    Actors have:
    - A current state
    - Local storage (key-value)
    - A message queue
    - A chain reference
    """
    peer_id: str
    chain: Chain
    current_time: float = 0.0

    # Internal state
    state: ActorState = None
    local_store: Dict[str, Any] = field(default_factory=dict)
    message_queue: List[Message] = field(default_factory=list)

    # For tracking state transitions
    state_history: List[Tuple[float, ActorState]] = field(default_factory=list)

    def store(self, key: str, value: Any):
        """Store a value in local state."""
        self.local_store[key] = value

    def load(self, key: str, default: Any = None) -> Any:
        """Load a value from local state."""
        return self.local_store.get(key, default)

    def receive_message(self, msg: Message):
        """Add a message to the queue."""
        self.message_queue.append(msg)

    def get_messages(self, msg_type: MessageType = None) -> List[Message]:
        """Get messages from queue, optionally filtered by type."""
        if msg_type is None:
            return self.message_queue
        return [m for m in self.message_queue if m.msg_type == msg_type]

    def clear_messages(self, msg_type: MessageType = None):
        """Clear messages from queue."""
        if msg_type is None:
            self.message_queue = []
        else:
            self.message_queue = [m for m in self.message_queue if m.msg_type != msg_type]

    def transition_to(self, new_state: ActorState):
        """Transition to a new state."""
        self.state_history.append((self.current_time, self.state))
        self.state = new_state

    def tick(self, current_time: float) -> List[Message]:
        """
        Process one tick of the state machine.

        Returns list of outgoing messages.
        """
        self.current_time = current_time
        raise NotImplementedError("Subclasses must implement tick()")


# =============================================================================
# Consumer States
# =============================================================================

class ConsumerState(ActorState):
    IDLE = auto()
    SENDING_LOCK_INTENT = auto()
    WAITING_FOR_WITNESS_COMMITMENT = auto()
    VERIFYING_PROVIDER_CHAIN = auto()
    VERIFYING_WITNESSES = auto()
    SENDING_REQUESTS = auto()
    WAITING_FOR_RESULT = auto()
    REVIEWING_RESULT = auto()
    SIGNING_RESULT = auto()
    LOCKED = auto()
    FAILED = auto()
    # Top-up states (mid-session additional funding)
    SENDING_TOPUP = auto()
    WAITING_FOR_TOPUP_RESULT = auto()
    REVIEWING_TOPUP_RESULT = auto()
    SIGNING_TOPUP = auto()


@dataclass
class Consumer(Actor):
    """Consumer actor in escrow lock protocol."""

    state: ConsumerState = ConsumerState.IDLE

    def initiate_lock(self, provider: str, amount: float):
        """Initiate a lock request."""
        self.store("provider", provider)
        self.store("amount", amount)
        self.store("session_id", hash_data({
            "consumer": self.peer_id,
            "provider": provider,
            "time": self.current_time
        }))
        self.store("consumer_nonce", random_bytes(32))

        # Find checkpoint from our chain
        checkpoint_block = self.chain.get_peer_hash(provider)
        if checkpoint_block is None:
            self.store("reject_reason", "no_prior_provider_checkpoint")
            self.transition_to(ConsumerState.FAILED)
            return

        self.store("provider_checkpoint", checkpoint_block.payload["hash"])
        self.store("checkpoint_timestamp", checkpoint_block.timestamp)
        self.transition_to(ConsumerState.SENDING_LOCK_INTENT)

    def initiate_topup(self, additional_amount: float):
        """
        Initiate a top-up request for an active escrow.

        Must be called when consumer is in LOCKED state.
        """
        if self.state != ConsumerState.LOCKED:
            raise ValueError("Can only top-up when in LOCKED state")

        lock_result = self.load("lock_result")
        if not lock_result:
            raise ValueError("No active lock result to top-up")

        self.store("additional_amount", additional_amount)
        self.store("current_lock_hash", hash_data(lock_result))
        self.store("topup_sent_at", self.current_time)
        self.transition_to(ConsumerState.SENDING_TOPUP)

    @property
    def is_locked(self) -> bool:
        """Check if consumer has active escrow."""
        return self.state == ConsumerState.LOCKED

    @property
    def is_failed(self) -> bool:
        """Check if consumer is in failed state."""
        return self.state == ConsumerState.FAILED

    @property
    def total_escrowed(self) -> float:
        """Get total amount currently escrowed."""
        return self.load("total_escrowed", 0.0)

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the consumer state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ConsumerState.IDLE:
            # Waiting for initiate_lock() call
            pass

        elif self.state == ConsumerState.SENDING_LOCK_INTENT:
            # Send LOCK_INTENT to provider
            intent = {
                "consumer": self.peer_id,
                "provider": self.load("provider"),
                "amount": self.load("amount"),
                "session_id": self.load("session_id"),
                "consumer_nonce": self.load("consumer_nonce").hex(),
                "provider_chain_checkpoint": self.load("provider_checkpoint"),
                "checkpoint_timestamp": self.load("checkpoint_timestamp"),
                "timestamp": current_time,
            }
            intent["signature"] = sign(self.chain.private_key, hash_data(intent))

            outgoing.append(Message(
                msg_type=MessageType.LOCK_INTENT,
                sender=self.peer_id,
                payload=intent,
                timestamp=current_time,
            ))

            self.store("intent_sent_at", current_time)
            self.transition_to(ConsumerState.WAITING_FOR_WITNESS_COMMITMENT)

        elif self.state == ConsumerState.WAITING_FOR_WITNESS_COMMITMENT:
            # Check for commitment message
            commitments = self.get_messages(MessageType.WITNESS_SELECTION_COMMITMENT)
            rejections = self.get_messages(MessageType.LOCK_REJECTED)

            if commitments:
                msg = commitments[0]
                self.store("provider_nonce", msg.payload["provider_nonce"])
                self.store("provider_chain_segment", msg.payload["provider_chain_segment"])
                self.store("selection_inputs", msg.payload["selection_inputs"])
                self.store("proposed_witnesses", msg.payload["witnesses"])
                self.clear_messages(MessageType.WITNESS_SELECTION_COMMITMENT)
                self.transition_to(ConsumerState.VERIFYING_PROVIDER_CHAIN)

            elif rejections:
                msg = rejections[0]
                self.store("reject_reason", msg.payload.get("reason", "provider_rejected"))
                self.clear_messages(MessageType.LOCK_REJECTED)
                self.transition_to(ConsumerState.FAILED)

            elif current_time - self.load("intent_sent_at", 0) > WITNESS_COMMITMENT_TIMEOUT:
                self.store("reject_reason", "provider_timeout")
                self.transition_to(ConsumerState.FAILED)

        elif self.state == ConsumerState.VERIFYING_PROVIDER_CHAIN:
            # Verify provider's chain segment
            chain_segment = self.load("provider_chain_segment")
            checkpoint = self.load("provider_checkpoint")

            # Simplified verification - in real impl would verify signatures
            valid = True
            checkpoint_found = False

            for block in chain_segment:
                if block.get("block_hash") == checkpoint:
                    checkpoint_found = True
                    break

            if not checkpoint_found:
                self.store("reject_reason", "checkpoint_not_in_chain")
                self.transition_to(ConsumerState.FAILED)
            else:
                # Extract chain state at checkpoint
                self.store("verified_chain_state", self.load("selection_inputs"))
                self.transition_to(ConsumerState.VERIFYING_WITNESSES)

        elif self.state == ConsumerState.VERIFYING_WITNESSES:
            # Recompute witness selection and verify it matches
            # Simplified - in real impl would recompute deterministically
            witnesses = self.load("proposed_witnesses")

            if len(witnesses) < WITNESS_THRESHOLD:
                self.store("reject_reason", "insufficient_witnesses")
                self.transition_to(ConsumerState.FAILED)
            else:
                self.store("witnesses", witnesses)
                self.transition_to(ConsumerState.SENDING_REQUESTS)

        elif self.state == ConsumerState.SENDING_REQUESTS:
            # Send WITNESS_REQUEST to all witnesses
            witnesses = self.load("witnesses")
            request = {
                "consumer": self.peer_id,
                "provider": self.load("provider"),
                "amount": self.load("amount"),
                "session_id": self.load("session_id"),
                "my_chain_head": self.chain.head_hash,
                "witnesses": witnesses,
                "timestamp": current_time,
            }
            request["signature"] = sign(self.chain.private_key, hash_data(request))

            for witness in witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.WITNESS_REQUEST,
                    sender=self.peer_id,
                    payload=request,
                    timestamp=current_time,
                ))

            self.store("requests_sent_at", current_time)
            self.transition_to(ConsumerState.WAITING_FOR_RESULT)

        elif self.state == ConsumerState.WAITING_FOR_RESULT:
            # Wait for LOCK_RESULT_FOR_SIGNATURE from witnesses
            results = self.get_messages(MessageType.LOCK_RESULT_FOR_SIGNATURE)

            if results:
                msg = results[0]
                self.store("pending_result", msg.payload["result"])
                self.store("result_sender", msg.sender)
                self.clear_messages(MessageType.LOCK_RESULT_FOR_SIGNATURE)
                self.transition_to(ConsumerState.REVIEWING_RESULT)

            elif current_time - self.load("requests_sent_at", 0) > RECRUITMENT_TIMEOUT:
                self.store("reject_reason", "witness_timeout")
                self.transition_to(ConsumerState.FAILED)

        elif self.state == ConsumerState.REVIEWING_RESULT:
            # Verify the result matches what we requested
            result = self.load("pending_result")

            if result["session_id"] != self.load("session_id"):
                self.store("reject_reason", "session_id_mismatch")
                self.transition_to(ConsumerState.FAILED)
            elif result["consumer"] != self.peer_id:
                self.store("reject_reason", "consumer_mismatch")
                self.transition_to(ConsumerState.FAILED)
            elif result["amount"] != self.load("amount"):
                self.store("reject_reason", "amount_mismatch")
                self.transition_to(ConsumerState.FAILED)
            elif result["status"] == "rejected":
                self.store("reject_reason", "witnesses_rejected")
                self.transition_to(ConsumerState.FAILED)
            else:
                # Verify witness signatures (simplified)
                valid_sigs = len(result.get("witness_signatures", []))
                if valid_sigs < WITNESS_THRESHOLD:
                    self.store("reject_reason", "insufficient_witness_signatures")
                    self.transition_to(ConsumerState.FAILED)
                else:
                    self.transition_to(ConsumerState.SIGNING_RESULT)

        elif self.state == ConsumerState.SIGNING_RESULT:
            # Counter-sign the result
            result = self.load("pending_result")
            consumer_sig = sign(self.chain.private_key, hash_data(result))
            result["consumer_signature"] = consumer_sig
            self.store("lock_result", result)

            # Record on our chain
            self.chain.append(
                BlockType.BALANCE_LOCK,
                {
                    "session_id": result["session_id"],
                    "amount": result["amount"],
                    "lock_result_hash": hash_data(result),
                    "timestamp": current_time,
                },
                current_time,
            )

            # Send signed result back to witnesses
            signed_msg = {
                "session_id": result["session_id"],
                "consumer_signature": consumer_sig,
                "timestamp": current_time,
            }

            for witness in self.load("witnesses"):
                outgoing.append(Message(
                    msg_type=MessageType.CONSUMER_SIGNED_LOCK,
                    sender=self.peer_id,
                    payload=signed_msg,
                    timestamp=current_time,
                ))

            # Track total escrowed amount
            self.store("total_escrowed", result["amount"])
            self.transition_to(ConsumerState.LOCKED)

        elif self.state == ConsumerState.LOCKED:
            # Escrow is locked, respond to liveness pings
            pings = self.get_messages(MessageType.LIVENESS_PING)
            for ping in pings:
                pong = {
                    "session_id": ping.payload["session_id"],
                    "from_witness": self.peer_id,
                    "timestamp": current_time,
                }
                pong["signature"] = sign(self.chain.private_key, hash_data(pong))
                outgoing.append(Message(
                    msg_type=MessageType.LIVENESS_PONG,
                    sender=self.peer_id,
                    payload=pong,
                    timestamp=current_time,
                ))
            self.clear_messages(MessageType.LIVENESS_PING)
            # Note: initiate_topup() can transition out of LOCKED state

        elif self.state == ConsumerState.SENDING_TOPUP:
            # Send TOPUP_INTENT to existing witnesses
            witnesses = self.load("witnesses")
            intent = {
                "session_id": self.load("session_id"),
                "consumer": self.peer_id,
                "additional_amount": self.load("additional_amount"),
                "current_lock_result_hash": self.load("current_lock_hash"),
                "timestamp": current_time,
            }
            intent["signature"] = sign(self.chain.private_key, hash_data(intent))

            for witness in witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.TOPUP_INTENT,
                    sender=self.peer_id,
                    payload=intent,
                    timestamp=current_time,
                ))

            self.store("topup_sent_at", current_time)
            self.transition_to(ConsumerState.WAITING_FOR_TOPUP_RESULT)

        elif self.state == ConsumerState.WAITING_FOR_TOPUP_RESULT:
            # Wait for TOPUP_RESULT_FOR_SIGNATURE from witnesses
            results = self.get_messages(MessageType.TOPUP_RESULT_FOR_SIGNATURE)

            if results:
                msg = results[0]
                self.store("pending_topup_result", msg.payload["result"])
                self.clear_messages(MessageType.TOPUP_RESULT_FOR_SIGNATURE)
                self.transition_to(ConsumerState.REVIEWING_TOPUP_RESULT)

            elif current_time - self.load("topup_sent_at", 0) > CONSENSUS_TIMEOUT:
                # Top-up failed, return to LOCKED state with existing escrow
                self.store("topup_failed_reason", "timeout")
                self.transition_to(ConsumerState.LOCKED)

        elif self.state == ConsumerState.REVIEWING_TOPUP_RESULT:
            # Verify the top-up result matches what we requested
            result = self.load("pending_topup_result")

            if result["session_id"] != self.load("session_id"):
                self.store("topup_failed_reason", "session_id_mismatch")
                self.transition_to(ConsumerState.LOCKED)
            elif result["consumer"] != self.peer_id:
                self.store("topup_failed_reason", "consumer_mismatch")
                self.transition_to(ConsumerState.LOCKED)
            elif result["additional_amount"] != self.load("additional_amount"):
                self.store("topup_failed_reason", "amount_mismatch")
                self.transition_to(ConsumerState.LOCKED)
            elif result.get("status") == "rejected":
                self.store("topup_failed_reason", "witnesses_rejected")
                self.transition_to(ConsumerState.LOCKED)
            else:
                # Verify witness signatures (simplified)
                valid_sigs = len(result.get("witness_signatures", []))
                if valid_sigs < WITNESS_THRESHOLD:
                    self.store("topup_failed_reason", "insufficient_witness_signatures")
                    self.transition_to(ConsumerState.LOCKED)
                else:
                    self.transition_to(ConsumerState.SIGNING_TOPUP)

        elif self.state == ConsumerState.SIGNING_TOPUP:
            # Counter-sign the top-up result
            result = self.load("pending_topup_result")
            consumer_sig = sign(self.chain.private_key, hash_data(result))
            result["consumer_signature"] = consumer_sig
            self.store("topup_result", result)

            # Record on our chain
            self.chain.append(
                BlockType.BALANCE_TOPUP,
                {
                    "session_id": result["session_id"],
                    "previous_total": result["previous_total"],
                    "topup_amount": result["additional_amount"],
                    "new_total": result["new_total"],
                    "topup_result_hash": hash_data(result),
                    "timestamp": current_time,
                },
                current_time,
            )

            # Send signed result back to witnesses
            signed_msg = {
                "session_id": result["session_id"],
                "consumer_signature": consumer_sig,
                "timestamp": current_time,
            }

            for witness in self.load("witnesses"):
                outgoing.append(Message(
                    msg_type=MessageType.CONSUMER_SIGNED_TOPUP,
                    sender=self.peer_id,
                    payload=signed_msg,
                    timestamp=current_time,
                ))

            # Update total escrowed
            self.store("total_escrowed", result["new_total"])
            self.transition_to(ConsumerState.LOCKED)

        elif self.state == ConsumerState.FAILED:
            # Terminal state - clean up
            self.store("witnesses", [])
            self.store("pending_result", None)

        return outgoing


# =============================================================================
# Provider States
# =============================================================================

class ProviderState(ActorState):
    IDLE = auto()
    VALIDATING_CHECKPOINT = auto()
    SELECTING_WITNESSES = auto()
    SENDING_COMMITMENT = auto()
    WAITING_FOR_LOCK = auto()
    SERVICE_PHASE = auto()


@dataclass
class Provider(Actor):
    """Provider actor in escrow lock protocol."""

    state: ProviderState = ProviderState.IDLE

    # Network reference for witness selection
    network: Any = None  # Will be set to Network instance

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the provider state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ProviderState.IDLE:
            # Check for LOCK_INTENT
            intents = self.get_messages(MessageType.LOCK_INTENT)
            if intents:
                msg = intents[0]
                self.store("consumer", msg.sender)
                self.store("amount", msg.payload["amount"])
                self.store("session_id", msg.payload["session_id"])
                self.store("consumer_nonce", bytes.fromhex(msg.payload["consumer_nonce"]))
                self.store("requested_checkpoint", msg.payload["provider_chain_checkpoint"])
                self.store("checkpoint_timestamp", msg.payload["checkpoint_timestamp"])
                self.store("provider_nonce", random_bytes(32))
                self.clear_messages(MessageType.LOCK_INTENT)
                self.transition_to(ProviderState.VALIDATING_CHECKPOINT)

        elif self.state == ProviderState.VALIDATING_CHECKPOINT:
            checkpoint = self.load("requested_checkpoint")

            # Verify checkpoint exists in our chain
            if not self.chain.contains_hash(checkpoint):
                # Reject - unknown checkpoint
                outgoing.append(Message(
                    msg_type=MessageType.LOCK_REJECTED,
                    sender=self.peer_id,
                    payload={
                        "session_id": self.load("session_id"),
                        "reason": "unknown_checkpoint",
                        "timestamp": current_time,
                    },
                    timestamp=current_time,
                ))
                self.transition_to(ProviderState.IDLE)
            else:
                # Extract chain state at checkpoint
                chain_state = self.chain.get_state_at(checkpoint)
                self.store("chain_state_at_checkpoint", chain_state)

                # Extract chain segment
                chain_segment = self.chain.to_segment(to_hash=checkpoint)
                self.store("chain_segment", chain_segment)

                self.transition_to(ProviderState.SELECTING_WITNESSES)

        elif self.state == ProviderState.SELECTING_WITNESSES:
            chain_state = self.load("chain_state_at_checkpoint")

            # Compute deterministic selection
            seed = hash_data({
                "session_id": self.load("session_id"),
                "provider_nonce": self.load("provider_nonce").hex(),
                "consumer_nonce": self.load("consumer_nonce").hex(),
            }).encode()

            # Use network's selection function if available
            if self.network:
                witnesses = self.network.select_witnesses_deterministic(
                    seed=seed,
                    chain_state=chain_state,
                    count=WITNESS_COUNT,
                    exclude=[self.peer_id, self.load("consumer")],
                    interaction_with=self.load("consumer"),
                )
            else:
                # Fallback: just use known peers from chain state
                known_peers = chain_state.get("known_peers", [])
                exclude = [self.peer_id, self.load("consumer")]
                witnesses = [p for p in known_peers if p not in exclude][:WITNESS_COUNT]

            self.store("witnesses", witnesses)

            # Capture selection inputs for consumer verification
            selection_inputs = {
                "known_peers": chain_state.get("known_peers", []),
                "trust_scores": chain_state.get("trust_scores", {}),
                "interaction_counts": chain_state.get("interaction_counts", {}),
            }
            self.store("selection_inputs", selection_inputs)

            self.transition_to(ProviderState.SENDING_COMMITMENT)

        elif self.state == ProviderState.SENDING_COMMITMENT:
            commitment = {
                "session_id": self.load("session_id"),
                "provider": self.peer_id,
                "provider_nonce": self.load("provider_nonce").hex(),
                "provider_chain_segment": self.load("chain_segment"),
                "selection_inputs": self.load("selection_inputs"),
                "witnesses": self.load("witnesses"),
                "timestamp": current_time,
            }
            commitment["signature"] = sign(self.chain.private_key, hash_data(commitment))

            outgoing.append(Message(
                msg_type=MessageType.WITNESS_SELECTION_COMMITMENT,
                sender=self.peer_id,
                payload=commitment,
                timestamp=current_time,
            ))

            self.store("commitment_sent_at", current_time)
            self.transition_to(ProviderState.WAITING_FOR_LOCK)

        elif self.state == ProviderState.WAITING_FOR_LOCK:
            # Wait for BALANCE_UPDATE_BROADCAST indicating lock completed
            updates = self.get_messages(MessageType.BALANCE_UPDATE_BROADCAST)

            for msg in updates:
                result = msg.payload.get("lock_result", {})
                if (result.get("session_id") == self.load("session_id") and
                    result.get("status") == "accepted"):
                    self.store("lock_result", result)
                    self.clear_messages(MessageType.BALANCE_UPDATE_BROADCAST)
                    self.transition_to(ProviderState.SERVICE_PHASE)
                    break

            if current_time - self.load("commitment_sent_at", 0) > LOCK_TIMEOUT:
                # Consumer didn't complete lock
                self.store("session_id", None)
                self.transition_to(ProviderState.IDLE)

        elif self.state == ProviderState.SERVICE_PHASE:
            # Provider is now providing service
            # Settlement protocol would follow (Step 1)
            pass

        return outgoing


# =============================================================================
# Witness States
# =============================================================================

class WitnessState(ActorState):
    IDLE = auto()
    CHECKING_CHAIN_KNOWLEDGE = auto()
    REQUESTING_CHAIN_SYNC = auto()
    WAITING_FOR_CHAIN_SYNC = auto()
    CHECKING_BALANCE = auto()
    CHECKING_EXISTING_LOCKS = auto()
    SHARING_PRELIMINARY = auto()
    COLLECTING_PRELIMINARIES = auto()
    EVALUATING_PRELIMINARIES = auto()
    VOTING = auto()
    COLLECTING_VOTES = auto()
    EVALUATING_VOTES = auto()
    RECRUITING_MORE = auto()
    WAITING_FOR_RECRUITS = auto()
    SIGNING_RESULT = auto()
    COLLECTING_SIGNATURES = auto()
    PROPAGATING = auto()
    WAITING_FOR_CONSUMER_SIGNATURE = auto()
    FINALIZING = auto()
    ESCROW_ACTIVE = auto()
    DONE = auto()
    REJECTED = auto()
    # Top-up states (mid-session additional funding)
    CHECKING_TOPUP_BALANCE = auto()
    VOTING_TOPUP = auto()
    COLLECTING_TOPUP_VOTES = auto()
    SIGNING_TOPUP_RESULT = auto()
    COLLECTING_TOPUP_SIGNATURES = auto()
    PROPAGATING_TOPUP = auto()
    WAITING_FOR_CONSUMER_TOPUP_SIGNATURE = auto()


@dataclass
class Witness(Actor):
    """Witness actor in escrow lock protocol."""

    state: WitnessState = WitnessState.IDLE

    def tick(self, current_time: float) -> List[Message]:
        """Process one tick of the witness state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == WitnessState.IDLE:
            # Check for WITNESS_REQUEST or WITNESS_RECRUIT_REQUEST
            requests = self.get_messages(MessageType.WITNESS_REQUEST)
            recruits = self.get_messages(MessageType.WITNESS_RECRUIT_REQUEST)

            if requests:
                msg = requests[0]
                self.store("request", msg.payload)
                self.store("consumer", msg.sender)
                self.store("other_witnesses", [
                    w for w in msg.payload["witnesses"] if w != self.peer_id
                ])
                self.store("preliminaries", [])
                self.store("votes", [])
                self.store("signatures", [])
                self.store("recruitment_round", 0)
                self.clear_messages(MessageType.WITNESS_REQUEST)
                self.transition_to(WitnessState.CHECKING_CHAIN_KNOWLEDGE)

            elif recruits:
                msg = recruits[0]
                self.store("request", {
                    "consumer": msg.payload["consumer"],
                    "provider": msg.payload["provider"],
                    "amount": msg.payload["amount"],
                    "session_id": msg.payload["session_id"],
                    "witnesses": msg.payload["existing_witnesses"] + [self.peer_id],
                })
                self.store("consumer", msg.payload["consumer"])
                self.store("other_witnesses", msg.payload["existing_witnesses"])
                self.store("preliminaries", [])
                self.store("votes", msg.payload.get("existing_votes", []))
                self.store("signatures", [])
                self.store("recruitment_round", self.load("recruitment_round", 0) + 1)
                self.clear_messages(MessageType.WITNESS_RECRUIT_REQUEST)
                self.transition_to(WitnessState.CHECKING_CHAIN_KNOWLEDGE)

        elif self.state == WitnessState.CHECKING_CHAIN_KNOWLEDGE:
            consumer = self.load("consumer")

            # Check if we have recent knowledge of consumer's chain
            last_seen = self.chain.get_peer_hash(consumer)
            self.store("last_seen_record", last_seen)

            if last_seen is None:
                self.transition_to(WitnessState.REQUESTING_CHAIN_SYNC)
            else:
                age = current_time - last_seen.timestamp
                if age > MAX_CHAIN_AGE:
                    self.transition_to(WitnessState.REQUESTING_CHAIN_SYNC)
                else:
                    self.transition_to(WitnessState.CHECKING_BALANCE)

        elif self.state == WitnessState.REQUESTING_CHAIN_SYNC:
            # Request chain data from other witnesses
            consumer = self.load("consumer")
            other_witnesses = self.load("other_witnesses")

            sync_request = {
                "session_id": self.load("request")["session_id"],
                "consumer": consumer,
                "requesting_witness": self.peer_id,
                "timestamp": current_time,
            }
            sync_request["signature"] = sign(self.chain.private_key, hash_data(sync_request))

            for witness in other_witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.WITNESS_CHAIN_SYNC_REQUEST,
                    sender=self.peer_id,
                    payload=sync_request,
                    timestamp=current_time,
                ))

            self.store("sync_requested_at", current_time)
            self.transition_to(WitnessState.WAITING_FOR_CHAIN_SYNC)

        elif self.state == WitnessState.WAITING_FOR_CHAIN_SYNC:
            responses = self.get_messages(MessageType.WITNESS_CHAIN_SYNC_RESPONSE)

            if responses:
                msg = responses[0]
                self.store("synced_chain_head", msg.payload["chain_head"])
                self.store("synced_chain_data", msg.payload["chain_data"])
                self.clear_messages(MessageType.WITNESS_CHAIN_SYNC_RESPONSE)
                self.transition_to(WitnessState.CHECKING_BALANCE)

            elif current_time - self.load("sync_requested_at", 0) > PRELIMINARY_TIMEOUT:
                # No one could help, reject
                self.store("reject_reason", "no_chain_knowledge_available")
                self.store("verdict", WitnessVerdict.REJECT)
                self.transition_to(WitnessState.SHARING_PRELIMINARY)

        elif self.state == WitnessState.CHECKING_BALANCE:
            consumer = self.load("consumer")
            request = self.load("request")

            # Get balance from synced or cached chain
            if self.load("synced_chain_data"):
                # Would parse chain data to get balance
                balance = 100.0  # Simplified
            else:
                # Use cached data
                balance = self.load("cached_chains", {}).get(consumer, {}).get("balance", 0.0)

            self.store("observed_balance", balance)
            self.store("observed_chain_head", self.load("synced_chain_head") or "unknown")

            if balance < request["amount"]:
                self.store("reject_reason", "insufficient_balance")
                self.store("verdict", WitnessVerdict.REJECT)
                self.transition_to(WitnessState.SHARING_PRELIMINARY)
            else:
                self.transition_to(WitnessState.CHECKING_EXISTING_LOCKS)

        elif self.state == WitnessState.CHECKING_EXISTING_LOCKS:
            # Check for existing locks
            total_locked = 0.0  # Simplified - would read from chain

            balance = self.load("observed_balance")
            request = self.load("request")

            if balance - total_locked < request["amount"]:
                self.store("reject_reason", "balance_already_locked")
                self.store("verdict", WitnessVerdict.REJECT)
            else:
                self.store("verdict", WitnessVerdict.ACCEPT)
                self.store("reject_reason", None)

            self.transition_to(WitnessState.SHARING_PRELIMINARY)

        elif self.state == WitnessState.SHARING_PRELIMINARY:
            request = self.load("request")
            other_witnesses = self.load("other_witnesses")

            preliminary = {
                "session_id": request["session_id"],
                "witness": self.peer_id,
                "verdict": self.load("verdict").value,
                "observed_balance": self.load("observed_balance"),
                "observed_chain_head": self.load("observed_chain_head"),
                "reject_reason": self.load("reject_reason"),
                "timestamp": current_time,
            }
            preliminary["signature"] = sign(self.chain.private_key, hash_data(preliminary))

            for witness in other_witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.WITNESS_PRELIMINARY,
                    sender=self.peer_id,
                    payload=preliminary,
                    timestamp=current_time,
                ))

            # Add own preliminary to collection
            self.store("preliminaries", [preliminary])
            self.store("preliminary_sent_at", current_time)
            self.transition_to(WitnessState.COLLECTING_PRELIMINARIES)

        elif self.state == WitnessState.COLLECTING_PRELIMINARIES:
            # Handle incoming sync requests while collecting
            sync_requests = self.get_messages(MessageType.WITNESS_CHAIN_SYNC_REQUEST)
            cached_chains = self.load("cached_chains", {})
            for req in sync_requests:
                consumer = req.payload["consumer"]
                if consumer in cached_chains:
                    response = {
                        "session_id": req.payload["session_id"],
                        "consumer": consumer,
                        "chain_data": cached_chains[consumer],
                        "chain_head": cached_chains[consumer].get("head_hash", "unknown"),
                        "timestamp": current_time,
                    }
                    response["signature"] = sign(self.chain.private_key, hash_data(response))
                    outgoing.append(Message(
                        msg_type=MessageType.WITNESS_CHAIN_SYNC_RESPONSE,
                        sender=self.peer_id,
                        payload=response,
                        timestamp=current_time,
                    ))
            self.clear_messages(MessageType.WITNESS_CHAIN_SYNC_REQUEST)

            # Collect preliminaries
            prelim_msgs = self.get_messages(MessageType.WITNESS_PRELIMINARY)
            prelims = self.load("preliminaries")
            for msg in prelim_msgs:
                prelims.append(msg.payload)
            self.store("preliminaries", prelims)
            self.clear_messages(MessageType.WITNESS_PRELIMINARY)

            other_witnesses = self.load("other_witnesses")
            if len(prelims) >= len(other_witnesses) + 1:
                self.transition_to(WitnessState.EVALUATING_PRELIMINARIES)
            elif current_time - self.load("preliminary_sent_at", 0) > PRELIMINARY_TIMEOUT:
                self.transition_to(WitnessState.EVALUATING_PRELIMINARIES)

        elif self.state == WitnessState.EVALUATING_PRELIMINARIES:
            prelims = self.load("preliminaries")
            accept_count = sum(1 for p in prelims if p["verdict"] == "accept")
            reject_count = len(prelims) - accept_count
            total = len(prelims)

            if total > 0:
                if accept_count / total >= CONSENSUS_THRESHOLD:
                    self.store("consensus_direction", "accept")
                elif reject_count / total >= CONSENSUS_THRESHOLD:
                    self.store("consensus_direction", "reject")
                else:
                    self.store("consensus_direction", "split")
            else:
                self.store("consensus_direction", "split")

            self.transition_to(WitnessState.VOTING)

        elif self.state == WitnessState.VOTING:
            request = self.load("request")
            other_witnesses = self.load("other_witnesses")

            vote = {
                "session_id": request["session_id"],
                "witness": self.peer_id,
                "vote": self.load("verdict").value,
                "observed_balance": self.load("observed_balance"),
                "timestamp": current_time,
            }
            vote["signature"] = sign(self.chain.private_key, hash_data(vote))

            for witness in other_witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.WITNESS_FINAL_VOTE,
                    sender=self.peer_id,
                    payload=vote,
                    timestamp=current_time,
                ))

            self.store("votes", [vote])
            self.store("votes_sent_at", current_time)
            self.transition_to(WitnessState.COLLECTING_VOTES)

        elif self.state == WitnessState.COLLECTING_VOTES:
            vote_msgs = self.get_messages(MessageType.WITNESS_FINAL_VOTE)
            votes = self.load("votes")
            for msg in vote_msgs:
                votes.append(msg.payload)
            self.store("votes", votes)
            self.clear_messages(MessageType.WITNESS_FINAL_VOTE)

            other_witnesses = self.load("other_witnesses")
            if len(votes) >= len(other_witnesses) + 1:
                self.transition_to(WitnessState.EVALUATING_VOTES)
            elif current_time - self.load("votes_sent_at", 0) > CONSENSUS_TIMEOUT:
                self.transition_to(WitnessState.EVALUATING_VOTES)

        elif self.state == WitnessState.EVALUATING_VOTES:
            votes = self.load("votes")
            accept_count = sum(1 for v in votes if v["vote"] == "accept")
            total = len(votes)

            if (accept_count >= WITNESS_THRESHOLD and
                total > 0 and accept_count / total >= CONSENSUS_THRESHOLD):
                self.store("final_result", "accepted")
            else:
                self.store("final_result", "rejected")

            self.transition_to(WitnessState.SIGNING_RESULT)

        elif self.state == WitnessState.SIGNING_RESULT:
            request = self.load("request")
            votes = self.load("votes")

            result = {
                "session_id": request["session_id"],
                "consumer": request["consumer"],
                "provider": request["provider"],
                "amount": request["amount"],
                "status": self.load("final_result"),
                "observed_balance": self.load("observed_balance"),
                "witnesses": [v["witness"] for v in votes],
                "witness_signatures": [],
                "consumer_signature": "",
                "timestamp": current_time,
            }

            my_sig = sign(self.chain.private_key, hash_data(result))
            result["witness_signatures"] = [my_sig]
            self.store("result", result)
            self.store("signatures", [{"witness": self.peer_id, "signature": my_sig}])

            # Share with other witnesses
            other_witnesses = self.load("other_witnesses")
            for witness in other_witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.LOCK_RESULT_FOR_SIGNATURE,
                    sender=self.peer_id,
                    payload={"result": result},
                    timestamp=current_time,
                ))

            self.store("signatures_sent_at", current_time)
            self.transition_to(WitnessState.COLLECTING_SIGNATURES)

        elif self.state == WitnessState.COLLECTING_SIGNATURES:
            sig_msgs = self.get_messages(MessageType.LOCK_RESULT_FOR_SIGNATURE)
            sigs = self.load("signatures")

            for msg in sig_msgs:
                # Extract signature from the result
                result = msg.payload.get("result", {})
                if result.get("witness_signatures"):
                    sigs.append({
                        "witness": msg.sender,
                        "signature": result["witness_signatures"][-1]
                    })
            self.store("signatures", sigs)
            self.clear_messages(MessageType.LOCK_RESULT_FOR_SIGNATURE)

            if len(sigs) >= WITNESS_THRESHOLD:
                self.transition_to(WitnessState.PROPAGATING)
            elif current_time - self.load("signatures_sent_at", 0) > CONSENSUS_TIMEOUT:
                if len(sigs) >= WITNESS_THRESHOLD:
                    self.transition_to(WitnessState.PROPAGATING)
                else:
                    self.transition_to(WitnessState.DONE)

        elif self.state == WitnessState.PROPAGATING:
            result = self.load("result")
            sigs = self.load("signatures")
            result["witness_signatures"] = [s["signature"] for s in sigs]
            self.store("result", result)

            # Send to consumer for counter-signature
            consumer = self.load("consumer")
            outgoing.append(Message(
                msg_type=MessageType.LOCK_RESULT_FOR_SIGNATURE,
                sender=self.peer_id,
                payload={"result": result},
                timestamp=current_time,
            ))

            self.store("propagated_at", current_time)
            self.transition_to(WitnessState.WAITING_FOR_CONSUMER_SIGNATURE)

        elif self.state == WitnessState.WAITING_FOR_CONSUMER_SIGNATURE:
            signed_msgs = self.get_messages(MessageType.CONSUMER_SIGNED_LOCK)

            if signed_msgs:
                msg = signed_msgs[0]
                result = self.load("result")
                result["consumer_signature"] = msg.payload["consumer_signature"]
                self.store("result", result)
                self.clear_messages(MessageType.CONSUMER_SIGNED_LOCK)
                self.transition_to(WitnessState.FINALIZING)

            elif current_time - self.load("propagated_at", 0) > CONSUMER_SIGNATURE_TIMEOUT:
                self.store("final_result", "consumer_abandoned")
                self.transition_to(WitnessState.DONE)

        elif self.state == WitnessState.FINALIZING:
            result = self.load("result")

            # Record on our chain
            self.chain.append(
                BlockType.WITNESS_COMMITMENT,
                {
                    "session_id": result["session_id"],
                    "consumer": result["consumer"],
                    "provider": result["provider"],
                    "amount": result["amount"],
                    "observed_balance": result["observed_balance"],
                    "witnesses": result["witnesses"],
                    "timestamp": current_time,
                },
                current_time,
            )

            # Broadcast to network
            outgoing.append(Message(
                msg_type=MessageType.BALANCE_UPDATE_BROADCAST,
                sender=self.peer_id,
                payload={
                    "consumer": result["consumer"],
                    "lock_result": result,
                    "timestamp": current_time,
                },
                timestamp=current_time,
            ))

            # Track total escrowed for this session
            self.store("total_escrowed", result["amount"])
            self.transition_to(WitnessState.ESCROW_ACTIVE)

        elif self.state == WitnessState.ESCROW_ACTIVE:
            # Escrow is locked, maintain liveness and handle top-ups
            # Respond to liveness pings
            pings = self.get_messages(MessageType.LIVENESS_PING)
            for ping in pings:
                pong = {
                    "session_id": ping.payload["session_id"],
                    "from_witness": self.peer_id,
                    "timestamp": current_time,
                }
                pong["signature"] = sign(self.chain.private_key, hash_data(pong))
                outgoing.append(Message(
                    msg_type=MessageType.LIVENESS_PONG,
                    sender=self.peer_id,
                    payload=pong,
                    timestamp=current_time,
                ))
            self.clear_messages(MessageType.LIVENESS_PING)

            # Check for top-up requests
            topup_intents = self.get_messages(MessageType.TOPUP_INTENT)
            if topup_intents:
                msg = topup_intents[0]
                self.store("topup_intent", msg.payload)
                self.clear_messages(MessageType.TOPUP_INTENT)
                self.transition_to(WitnessState.CHECKING_TOPUP_BALANCE)

        elif self.state == WitnessState.CHECKING_TOPUP_BALANCE:
            # Verify consumer has sufficient additional balance
            consumer = self.load("consumer")
            intent = self.load("topup_intent")
            additional = intent["additional_amount"]
            current_locked = self.load("total_escrowed", 0.0)

            # Get balance from cached chain data
            balance = self.load("cached_chains", {}).get(consumer, {}).get("balance", 0.0)
            free_balance = balance - current_locked

            self.store("topup_observed_balance", balance)
            self.store("topup_free_balance", free_balance)

            if free_balance < additional:
                self.store("topup_verdict", "reject")
                self.store("topup_reject_reason", "insufficient_free_balance")
            else:
                self.store("topup_verdict", "accept")
                self.store("topup_reject_reason", None)

            self.transition_to(WitnessState.VOTING_TOPUP)

        elif self.state == WitnessState.VOTING_TOPUP:
            # Share top-up vote with other witnesses
            intent = self.load("topup_intent")
            other_witnesses = self.load("other_witnesses")

            vote = {
                "session_id": intent["session_id"],
                "witness": self.peer_id,
                "vote": self.load("topup_verdict"),
                "additional_amount": intent["additional_amount"],
                "observed_balance": self.load("topup_observed_balance"),
                "timestamp": current_time,
            }
            vote["signature"] = sign(self.chain.private_key, hash_data(vote))

            for witness in other_witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.TOPUP_VOTE,
                    sender=self.peer_id,
                    payload=vote,
                    timestamp=current_time,
                ))

            self.store("topup_votes", [vote])
            self.store("topup_votes_sent_at", current_time)
            self.transition_to(WitnessState.COLLECTING_TOPUP_VOTES)

        elif self.state == WitnessState.COLLECTING_TOPUP_VOTES:
            # Collect votes from other witnesses
            vote_msgs = self.get_messages(MessageType.TOPUP_VOTE)
            votes = self.load("topup_votes")
            for msg in vote_msgs:
                votes.append(msg.payload)
            self.store("topup_votes", votes)
            self.clear_messages(MessageType.TOPUP_VOTE)

            other_witnesses = self.load("other_witnesses")
            if len(votes) >= len(other_witnesses) + 1:
                # Evaluate votes
                accept_count = sum(1 for v in votes if v["vote"] == "accept")
                total = len(votes)
                if accept_count >= WITNESS_THRESHOLD and accept_count / total >= CONSENSUS_THRESHOLD:
                    self.store("topup_final_result", "accepted")
                else:
                    self.store("topup_final_result", "rejected")
                self.transition_to(WitnessState.SIGNING_TOPUP_RESULT)
            elif current_time - self.load("topup_votes_sent_at", 0) > CONSENSUS_TIMEOUT:
                # Timeout - evaluate what we have
                accept_count = sum(1 for v in votes if v["vote"] == "accept")
                total = len(votes)
                if accept_count >= WITNESS_THRESHOLD and total > 0 and accept_count / total >= CONSENSUS_THRESHOLD:
                    self.store("topup_final_result", "accepted")
                else:
                    self.store("topup_final_result", "rejected")
                self.transition_to(WitnessState.SIGNING_TOPUP_RESULT)

        elif self.state == WitnessState.SIGNING_TOPUP_RESULT:
            # Create and sign top-up result
            intent = self.load("topup_intent")
            votes = self.load("topup_votes")
            result = self.load("result")  # Original lock result
            current_locked = self.load("total_escrowed", result.get("amount", 0.0))

            topup_result = {
                "session_id": intent["session_id"],
                "consumer": self.load("consumer"),
                "provider": result["provider"],
                "previous_total": current_locked,
                "additional_amount": intent["additional_amount"],
                "new_total": current_locked + intent["additional_amount"],
                "observed_balance": self.load("topup_observed_balance"),
                "status": self.load("topup_final_result"),
                "witnesses": [v["witness"] for v in votes],
                "witness_signatures": [],
                "consumer_signature": "",
                "timestamp": current_time,
            }

            my_sig = sign(self.chain.private_key, hash_data(topup_result))
            topup_result["witness_signatures"] = [my_sig]
            self.store("topup_result", topup_result)
            self.store("topup_signatures", [{"witness": self.peer_id, "signature": my_sig}])

            # Share with other witnesses
            other_witnesses = self.load("other_witnesses")
            for witness in other_witnesses:
                outgoing.append(Message(
                    msg_type=MessageType.TOPUP_RESULT_FOR_SIGNATURE,
                    sender=self.peer_id,
                    payload={"result": topup_result},
                    timestamp=current_time,
                ))

            self.store("topup_signatures_sent_at", current_time)
            self.transition_to(WitnessState.COLLECTING_TOPUP_SIGNATURES)

        elif self.state == WitnessState.COLLECTING_TOPUP_SIGNATURES:
            # Collect signatures from other witnesses
            sig_msgs = self.get_messages(MessageType.TOPUP_RESULT_FOR_SIGNATURE)
            sigs = self.load("topup_signatures")

            for msg in sig_msgs:
                result = msg.payload.get("result", {})
                if result.get("witness_signatures"):
                    sigs.append({
                        "witness": msg.sender,
                        "signature": result["witness_signatures"][-1]
                    })
            self.store("topup_signatures", sigs)
            self.clear_messages(MessageType.TOPUP_RESULT_FOR_SIGNATURE)

            if len(sigs) >= WITNESS_THRESHOLD:
                self.transition_to(WitnessState.PROPAGATING_TOPUP)
            elif current_time - self.load("topup_signatures_sent_at", 0) > CONSENSUS_TIMEOUT:
                if len(sigs) >= WITNESS_THRESHOLD:
                    self.transition_to(WitnessState.PROPAGATING_TOPUP)
                else:
                    # Not enough signatures, return to active escrow
                    self.transition_to(WitnessState.ESCROW_ACTIVE)

        elif self.state == WitnessState.PROPAGATING_TOPUP:
            # Send top-up result to consumer for counter-signature
            topup_result = self.load("topup_result")
            sigs = self.load("topup_signatures")
            topup_result["witness_signatures"] = [s["signature"] for s in sigs]
            self.store("topup_result", topup_result)

            consumer = self.load("consumer")
            outgoing.append(Message(
                msg_type=MessageType.TOPUP_RESULT_FOR_SIGNATURE,
                sender=self.peer_id,
                payload={"result": topup_result},
                timestamp=current_time,
            ))

            self.store("topup_propagated_at", current_time)
            self.transition_to(WitnessState.WAITING_FOR_CONSUMER_TOPUP_SIGNATURE)

        elif self.state == WitnessState.WAITING_FOR_CONSUMER_TOPUP_SIGNATURE:
            # Wait for consumer to counter-sign top-up
            signed_msgs = self.get_messages(MessageType.CONSUMER_SIGNED_TOPUP)

            if signed_msgs:
                msg = signed_msgs[0]
                topup_result = self.load("topup_result")
                topup_result["consumer_signature"] = msg.payload["consumer_signature"]
                self.store("topup_result", topup_result)
                self.clear_messages(MessageType.CONSUMER_SIGNED_TOPUP)

                # Record top-up on our chain
                self.chain.append(
                    BlockType.BALANCE_TOPUP,
                    {
                        "session_id": topup_result["session_id"],
                        "consumer": topup_result["consumer"],
                        "previous_total": topup_result["previous_total"],
                        "additional_amount": topup_result["additional_amount"],
                        "new_total": topup_result["new_total"],
                        "timestamp": current_time,
                    },
                    current_time,
                )

                # Update total escrowed
                self.store("total_escrowed", topup_result["new_total"])
                self.transition_to(WitnessState.ESCROW_ACTIVE)

            elif current_time - self.load("topup_propagated_at", 0) > CONSUMER_SIGNATURE_TIMEOUT:
                # Consumer didn't sign, return to active escrow
                self.transition_to(WitnessState.ESCROW_ACTIVE)

        elif self.state == WitnessState.DONE:
            # Clean up
            self.store("request", None)
            self.store("consumer", None)
            self.store("other_witnesses", [])
            self.store("preliminaries", [])
            self.store("votes", [])
            self.store("signatures", [])
            self.store("result", None)
            self.transition_to(WitnessState.IDLE)

        elif self.state == WitnessState.REJECTED:
            self.store("request", None)
            self.store("consumer", None)
            self.transition_to(WitnessState.IDLE)

        return outgoing


# =============================================================================
# Simulation Helper
# =============================================================================

class EscrowLockSimulation:
    """
    Helper class to run escrow lock simulations.

    Manages message passing between actors and time advancement.
    """

    def __init__(self, network):
        self.network = network
        self.actors: Dict[str, Actor] = {}
        self.current_time = network.current_time
        self.message_log: List[Message] = []

    def create_consumer(self, peer_id: str) -> Consumer:
        """Create a consumer actor."""
        chain = self.network.get_chain(peer_id)
        if not chain:
            raise ValueError(f"Unknown peer: {peer_id}")

        consumer = Consumer(
            peer_id=peer_id,
            chain=chain,
            current_time=self.current_time,
        )
        self.actors[peer_id] = consumer
        return consumer

    def create_provider(self, peer_id: str) -> Provider:
        """Create a provider actor."""
        chain = self.network.get_chain(peer_id)
        if not chain:
            raise ValueError(f"Unknown peer: {peer_id}")

        provider = Provider(
            peer_id=peer_id,
            chain=chain,
            current_time=self.current_time,
            network=self.network,
        )
        self.actors[peer_id] = provider
        return provider

    def create_witness(self, peer_id: str) -> Witness:
        """Create a witness actor."""
        chain = self.network.get_chain(peer_id)
        if not chain:
            raise ValueError(f"Unknown peer: {peer_id}")

        witness = Witness(
            peer_id=peer_id,
            chain=chain,
            current_time=self.current_time,
        )
        self.actors[peer_id] = witness
        return witness

    def route_message(self, msg: Message, recipient: str):
        """Route a message to a recipient actor."""
        if recipient in self.actors:
            self.actors[recipient].receive_message(msg)
            self.message_log.append(msg)

    def tick(self, time_step: float = 1.0) -> int:
        """
        Advance simulation by one tick.

        Returns number of messages sent.
        """
        self.current_time += time_step
        total_messages = 0

        for peer_id, actor in self.actors.items():
            outgoing = actor.tick(self.current_time)

            for msg in outgoing:
                total_messages += 1

                # Route to appropriate recipient(s)
                if msg.msg_type == MessageType.BALANCE_UPDATE_BROADCAST:
                    # Broadcast to all actors
                    for recipient in self.actors:
                        if recipient != msg.sender:
                            self.route_message(msg, recipient)
                else:
                    # Route based on message type
                    # For simplicity, route to all other actors
                    # Real impl would have explicit routing
                    for recipient in self.actors:
                        if recipient != msg.sender:
                            self.route_message(msg, recipient)

        return total_messages

    def run_until_stable(self, max_ticks: int = 100, time_step: float = 1.0) -> int:
        """
        Run simulation until no more messages are being sent.

        Returns number of ticks run.
        """
        for tick_num in range(max_ticks):
            messages = self.tick(time_step)
            if messages == 0:
                # Check if all actors are in stable states
                all_stable = True
                for actor in self.actors.values():
                    if isinstance(actor, Consumer):
                        if actor.state not in (ConsumerState.IDLE, ConsumerState.LOCKED, ConsumerState.FAILED):
                            all_stable = False
                    elif isinstance(actor, Provider):
                        if actor.state not in (ProviderState.IDLE, ProviderState.SERVICE_PHASE):
                            all_stable = False
                    elif isinstance(actor, Witness):
                        if actor.state not in (WitnessState.IDLE, WitnessState.ESCROW_ACTIVE, WitnessState.DONE):
                            all_stable = False

                if all_stable:
                    return tick_num + 1

        return max_ticks
