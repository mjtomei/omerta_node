"""
Cabal Attestation Transaction (Step 1)

Implements the state machines for VM allocation verification, session monitoring,
and attestation of service delivery.

Actors:
- Provider: allocates VM, notifies cabal, handles termination
- Consumer: connects to VM, uses service
- Witness (Cabal): verify VM accessibility, monitor session, create attestation

See: docs/protocol/transactions/01_cabal_attestation.md
"""

from enum import Enum, auto
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any

from ..chain.primitives import (
    Chain, Block, BlockType,
    hash_data, sign, verify_sig, generate_id
)


# =============================================================================
# Parameters
# =============================================================================

# Verification timeouts
VM_ALLOCATION_TIMEOUT = 300.0       # Provider must allocate within 5 min of lock
CONNECTIVITY_CHECK_TIMEOUT = 60.0   # Witnesses must verify within 1 min
CONNECTIVITY_VOTE_TIMEOUT = 30.0    # Time to collect connectivity votes
ABORT_VOTE_TIMEOUT = 30.0           # Time to collect abort votes

# Monitoring parameters
MONITORING_CHECK_INTERVAL = 60.0    # Check VM health every minute
MISUSE_INVESTIGATION_TIMEOUT = 120.0  # Time to investigate misuse accusation

# Thresholds
CONNECTIVITY_THRESHOLD = 0.67       # Fraction of witnesses that must verify connectivity
ABORT_THRESHOLD = 0.67              # Fraction needed to abort session
ATTESTATION_THRESHOLD = 3           # Minimum witnesses for valid attestation


# =============================================================================
# Termination Reasons
# =============================================================================

class TerminationReason(Enum):
    """Reasons for session termination."""
    COMPLETED_NORMAL = "completed_normal"       # Session ran full duration
    CONSUMER_REQUEST = "consumer_request"       # Consumer asked to stop early
    PROVIDER_VOLUNTARY = "provider_voluntary"   # Provider chose to stop
    VM_DIED = "vm_died"                         # VM crashed or became unreachable
    TIMEOUT = "timeout"                         # Session exceeded max duration
    CONSUMER_MISUSE = "consumer_misuse"         # Consumer violated terms
    ALLOCATION_FAILED = "allocation_failed"     # VM couldn't be allocated
    CONNECTIVITY_FAILED = "connectivity_failed" # Cabal couldn't verify VM


# =============================================================================
# Message Types
# =============================================================================

class AttestationMessageType(Enum):
    """Message types for cabal attestation protocol."""
    # Provider -> Cabal
    VM_ALLOCATED = auto()
    VM_CANCELLED = auto()
    MISUSE_ACCUSATION = auto()

    # Witness <-> Witness
    VM_CONNECTIVITY_VOTE = auto()
    ABORT_VOTE = auto()
    ATTESTATION_SHARE = auto()

    # Consumer -> Provider
    CANCEL_REQUEST = auto()

    # Provider -> Consumer
    VM_READY = auto()
    SESSION_TERMINATED = auto()

    # Witness -> Consumer/Provider
    ATTESTATION_RESULT = auto()


@dataclass
class AttestationMessage:
    """A message in the attestation protocol."""
    msg_type: AttestationMessageType
    sender: str
    payload: dict
    timestamp: float


# =============================================================================
# Provider States for Attestation
# =============================================================================

class ProviderAttestationState(Enum):
    """Provider states during attestation phase."""
    WAITING_FOR_LOCK = auto()       # Waiting for escrow lock to complete
    VM_PROVISIONING = auto()         # Allocating VM
    NOTIFYING_CABAL = auto()         # Sending VM_ALLOCATED to cabal
    WAITING_FOR_VERIFICATION = auto() # Waiting for cabal to verify
    VM_RUNNING = auto()              # Session active
    HANDLING_CANCEL = auto()         # Processing cancellation
    SENDING_CANCELLATION = auto()    # Notifying cabal of termination
    WAITING_FOR_ATTESTATION = auto() # Waiting for cabal attestation
    SESSION_COMPLETE = auto()        # Attestation received, ready for settlement
    SESSION_ABORTED = auto()         # Session was aborted


@dataclass
class ProviderAttestationActor:
    """Provider actor for attestation protocol."""
    peer_id: str
    chain: Chain
    current_time: float = 0.0

    state: ProviderAttestationState = ProviderAttestationState.WAITING_FOR_LOCK
    local_store: Dict[str, Any] = field(default_factory=dict)
    message_queue: List[AttestationMessage] = field(default_factory=list)

    def store(self, key: str, value: Any):
        self.local_store[key] = value

    def load(self, key: str, default: Any = None) -> Any:
        return self.local_store.get(key, default)

    def receive_message(self, msg: AttestationMessage):
        self.message_queue.append(msg)

    def get_messages(self, msg_type: AttestationMessageType = None) -> List[AttestationMessage]:
        if msg_type is None:
            return self.message_queue
        return [m for m in self.message_queue if m.msg_type == msg_type]

    def clear_messages(self, msg_type: AttestationMessageType = None):
        if msg_type is None:
            self.message_queue = []
        else:
            self.message_queue = [m for m in self.message_queue if m.msg_type != msg_type]

    def transition_to(self, new_state: ProviderAttestationState):
        self.state = new_state

    def start_session(self, session_id: str, consumer: str, witnesses: List[str], lock_result: dict):
        """Called after escrow lock succeeds to start VM allocation."""
        self.store("session_id", session_id)
        self.store("consumer", consumer)
        self.store("witnesses", witnesses)
        self.store("lock_result", lock_result)
        self.store("lock_completed_at", self.current_time)
        self.transition_to(ProviderAttestationState.VM_PROVISIONING)

    def allocate_vm(self, vm_info: dict):
        """Simulate VM allocation completing."""
        self.store("vm_info", vm_info)
        self.store("vm_allocated_at", self.current_time)
        self.transition_to(ProviderAttestationState.NOTIFYING_CABAL)

    def cancel_session(self, reason: TerminationReason):
        """Initiate session cancellation."""
        self.store("termination_reason", reason)
        self.store("cancelled_at", self.current_time)
        self.transition_to(ProviderAttestationState.HANDLING_CANCEL)

    def tick(self, current_time: float) -> List[AttestationMessage]:
        """Process one tick of the provider state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ProviderAttestationState.WAITING_FOR_LOCK:
            # Waiting for start_session() to be called
            pass

        elif self.state == ProviderAttestationState.VM_PROVISIONING:
            # Waiting for allocate_vm() to be called
            # Check for timeout
            lock_time = self.load("lock_completed_at", 0)
            if current_time - lock_time > VM_ALLOCATION_TIMEOUT:
                self.store("termination_reason", TerminationReason.ALLOCATION_FAILED)
                self.transition_to(ProviderAttestationState.SESSION_ABORTED)

        elif self.state == ProviderAttestationState.NOTIFYING_CABAL:
            # Send VM_ALLOCATED to all witnesses
            witnesses = self.load("witnesses", [])
            vm_info = self.load("vm_info", {})

            allocated_msg = {
                "session_id": self.load("session_id"),
                "provider": self.peer_id,
                "consumer": self.load("consumer"),
                "vm_wireguard_pubkey": vm_info.get("wireguard_pubkey", ""),
                "consumer_wireguard_endpoint": vm_info.get("consumer_endpoint", ""),
                "cabal_wireguard_endpoints": vm_info.get("cabal_endpoints", []),
                "allocated_at": self.load("vm_allocated_at"),
                "lock_result_hash": hash_data(self.load("lock_result", {})),
                "timestamp": current_time,
            }
            allocated_msg["provider_signature"] = sign(self.chain.private_key, hash_data(allocated_msg))
            self.store("vm_allocated_msg", allocated_msg)

            for witness in witnesses:
                outgoing.append(AttestationMessage(
                    msg_type=AttestationMessageType.VM_ALLOCATED,
                    sender=self.peer_id,
                    payload=allocated_msg,
                    timestamp=current_time,
                ))

            # Also notify consumer
            outgoing.append(AttestationMessage(
                msg_type=AttestationMessageType.VM_READY,
                sender=self.peer_id,
                payload={
                    "session_id": self.load("session_id"),
                    "vm_info": vm_info,
                    "timestamp": current_time,
                },
                timestamp=current_time,
            ))

            self.store("notified_at", current_time)
            self.transition_to(ProviderAttestationState.WAITING_FOR_VERIFICATION)

        elif self.state == ProviderAttestationState.WAITING_FOR_VERIFICATION:
            # Wait for connectivity votes from cabal
            votes = self.get_messages(AttestationMessageType.VM_CONNECTIVITY_VOTE)
            witnesses = self.load("witnesses", [])

            positive_votes = sum(1 for v in votes if v.payload.get("can_reach_vm", False))
            total_votes = len(votes)

            if total_votes >= len(witnesses):
                # All votes received
                if total_votes > 0 and positive_votes / total_votes >= CONNECTIVITY_THRESHOLD:
                    self.store("verification_passed", True)
                    self.clear_messages(AttestationMessageType.VM_CONNECTIVITY_VOTE)
                    self.transition_to(ProviderAttestationState.VM_RUNNING)
                else:
                    self.store("verification_passed", False)
                    self.store("termination_reason", TerminationReason.CONNECTIVITY_FAILED)
                    self.transition_to(ProviderAttestationState.SENDING_CANCELLATION)

            elif current_time - self.load("notified_at", 0) > CONNECTIVITY_CHECK_TIMEOUT:
                # Timeout - check if we have enough positive votes
                if total_votes > 0 and positive_votes / total_votes >= CONNECTIVITY_THRESHOLD:
                    self.store("verification_passed", True)
                    self.clear_messages(AttestationMessageType.VM_CONNECTIVITY_VOTE)
                    self.transition_to(ProviderAttestationState.VM_RUNNING)
                else:
                    self.store("verification_passed", False)
                    self.store("termination_reason", TerminationReason.CONNECTIVITY_FAILED)
                    self.transition_to(ProviderAttestationState.SENDING_CANCELLATION)

        elif self.state == ProviderAttestationState.VM_RUNNING:
            # Session is active
            # Check for cancel requests
            cancels = self.get_messages(AttestationMessageType.CANCEL_REQUEST)
            if cancels:
                msg = cancels[0]
                if msg.sender == self.load("consumer"):
                    self.store("termination_reason", TerminationReason.CONSUMER_REQUEST)
                else:
                    self.store("termination_reason", TerminationReason.PROVIDER_VOLUNTARY)
                self.store("cancelled_at", current_time)
                self.clear_messages(AttestationMessageType.CANCEL_REQUEST)
                self.transition_to(ProviderAttestationState.HANDLING_CANCEL)

        elif self.state == ProviderAttestationState.HANDLING_CANCEL:
            # Prepare cancellation
            self.transition_to(ProviderAttestationState.SENDING_CANCELLATION)

        elif self.state == ProviderAttestationState.SENDING_CANCELLATION:
            # Send VM_CANCELLED to cabal
            witnesses = self.load("witnesses", [])
            allocated_at = self.load("vm_allocated_at", current_time)
            cancelled_at = self.load("cancelled_at", current_time)

            cancelled_msg = {
                "session_id": self.load("session_id"),
                "provider": self.peer_id,
                "cancelled_at": cancelled_at,
                "reason": self.load("termination_reason", TerminationReason.PROVIDER_VOLUNTARY).value,
                "actual_duration_seconds": cancelled_at - allocated_at,
                "timestamp": current_time,
            }
            cancelled_msg["provider_signature"] = sign(self.chain.private_key, hash_data(cancelled_msg))
            self.store("vm_cancelled_msg", cancelled_msg)

            for witness in witnesses:
                outgoing.append(AttestationMessage(
                    msg_type=AttestationMessageType.VM_CANCELLED,
                    sender=self.peer_id,
                    payload=cancelled_msg,
                    timestamp=current_time,
                ))

            # Notify consumer
            outgoing.append(AttestationMessage(
                msg_type=AttestationMessageType.SESSION_TERMINATED,
                sender=self.peer_id,
                payload={
                    "session_id": self.load("session_id"),
                    "reason": self.load("termination_reason", TerminationReason.PROVIDER_VOLUNTARY).value,
                    "timestamp": current_time,
                },
                timestamp=current_time,
            ))

            self.store("cancellation_sent_at", current_time)
            self.transition_to(ProviderAttestationState.WAITING_FOR_ATTESTATION)

        elif self.state == ProviderAttestationState.WAITING_FOR_ATTESTATION:
            # Wait for attestation from cabal
            attestations = self.get_messages(AttestationMessageType.ATTESTATION_RESULT)
            if attestations:
                msg = attestations[0]
                self.store("attestation", msg.payload)
                self.clear_messages(AttestationMessageType.ATTESTATION_RESULT)
                self.transition_to(ProviderAttestationState.SESSION_COMPLETE)

        elif self.state == ProviderAttestationState.SESSION_COMPLETE:
            # Ready for settlement (Transaction 02)
            pass

        elif self.state == ProviderAttestationState.SESSION_ABORTED:
            # Session was aborted before completion
            pass

        return outgoing


# =============================================================================
# Witness States for Attestation
# =============================================================================

class WitnessAttestationState(Enum):
    """Witness states during attestation phase."""
    AWAITING_ALLOCATION = auto()     # Waiting for VM_ALLOCATED from provider
    VERIFYING_VM = auto()            # Checking VM connectivity
    COLLECTING_VOTES = auto()        # Collecting connectivity votes
    EVALUATING_CONNECTIVITY = auto() # Deciding if VM is accessible
    MONITORING = auto()              # Session running, periodic checks
    HANDLING_MISUSE = auto()         # Investigating misuse accusation
    VOTING_ABORT = auto()            # Voting to abort session
    COLLECTING_ABORT_VOTES = auto()  # Collecting abort votes
    ATTESTING = auto()               # Creating attestation after session ends
    COLLECTING_ATTESTATION_SIGS = auto()  # Multi-signing attestation
    PROPAGATING_ATTESTATION = auto() # Sending attestation to parties
    DONE = auto()                    # Attestation complete


@dataclass
class WitnessAttestationActor:
    """Witness actor for attestation protocol."""
    peer_id: str
    chain: Chain
    current_time: float = 0.0

    state: WitnessAttestationState = WitnessAttestationState.AWAITING_ALLOCATION
    local_store: Dict[str, Any] = field(default_factory=dict)
    message_queue: List[AttestationMessage] = field(default_factory=list)

    # For simulating connectivity checks
    can_reach_vm: bool = True
    can_see_consumer: bool = True

    def store(self, key: str, value: Any):
        self.local_store[key] = value

    def load(self, key: str, default: Any = None) -> Any:
        return self.local_store.get(key, default)

    def receive_message(self, msg: AttestationMessage):
        self.message_queue.append(msg)

    def get_messages(self, msg_type: AttestationMessageType = None) -> List[AttestationMessage]:
        if msg_type is None:
            return self.message_queue
        return [m for m in self.message_queue if m.msg_type == msg_type]

    def clear_messages(self, msg_type: AttestationMessageType = None):
        if msg_type is None:
            self.message_queue = []
        else:
            self.message_queue = [m for m in self.message_queue if m.msg_type != msg_type]

    def transition_to(self, new_state: WitnessAttestationState):
        self.state = new_state

    def setup_session(self, session_id: str, consumer: str, provider: str, other_witnesses: List[str]):
        """Initialize witness with session info (called after escrow lock)."""
        self.store("session_id", session_id)
        self.store("consumer", consumer)
        self.store("provider", provider)
        self.store("other_witnesses", other_witnesses)

    def tick(self, current_time: float) -> List[AttestationMessage]:
        """Process one tick of the witness state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == WitnessAttestationState.AWAITING_ALLOCATION:
            # Wait for VM_ALLOCATED from provider
            allocs = self.get_messages(AttestationMessageType.VM_ALLOCATED)
            if allocs:
                msg = allocs[0]
                self.store("vm_allocated_msg", msg.payload)
                self.store("vm_allocated_at", msg.payload.get("allocated_at", current_time))
                self.clear_messages(AttestationMessageType.VM_ALLOCATED)
                self.transition_to(WitnessAttestationState.VERIFYING_VM)

        elif self.state == WitnessAttestationState.VERIFYING_VM:
            # Simulate connectivity check
            # In real impl, would actually try wireguard connection
            connectivity_vote = {
                "session_id": self.load("session_id"),
                "witness": self.peer_id,
                "can_reach_vm": self.can_reach_vm,
                "can_see_consumer_connected": self.can_see_consumer,
                "timestamp": current_time,
            }
            connectivity_vote["signature"] = sign(self.chain.private_key, hash_data(connectivity_vote))
            self.store("my_connectivity_vote", connectivity_vote)

            # Send to other witnesses and provider
            other_witnesses = self.load("other_witnesses", [])
            provider = self.load("provider")

            for witness in other_witnesses:
                outgoing.append(AttestationMessage(
                    msg_type=AttestationMessageType.VM_CONNECTIVITY_VOTE,
                    sender=self.peer_id,
                    payload=connectivity_vote,
                    timestamp=current_time,
                ))

            # Also send to provider
            outgoing.append(AttestationMessage(
                msg_type=AttestationMessageType.VM_CONNECTIVITY_VOTE,
                sender=self.peer_id,
                payload=connectivity_vote,
                timestamp=current_time,
            ))

            self.store("connectivity_votes", [connectivity_vote])
            self.store("votes_sent_at", current_time)
            self.transition_to(WitnessAttestationState.COLLECTING_VOTES)

        elif self.state == WitnessAttestationState.COLLECTING_VOTES:
            # Collect votes from other witnesses
            votes = self.get_messages(AttestationMessageType.VM_CONNECTIVITY_VOTE)
            collected = self.load("connectivity_votes", [])

            for msg in votes:
                # Don't add our own vote again
                if msg.payload.get("witness") != self.peer_id:
                    collected.append(msg.payload)

            self.store("connectivity_votes", collected)
            self.clear_messages(AttestationMessageType.VM_CONNECTIVITY_VOTE)

            other_witnesses = self.load("other_witnesses", [])
            if len(collected) >= len(other_witnesses) + 1:
                self.transition_to(WitnessAttestationState.EVALUATING_CONNECTIVITY)
            elif current_time - self.load("votes_sent_at", 0) > CONNECTIVITY_VOTE_TIMEOUT:
                self.transition_to(WitnessAttestationState.EVALUATING_CONNECTIVITY)

        elif self.state == WitnessAttestationState.EVALUATING_CONNECTIVITY:
            # Evaluate connectivity votes
            votes = self.load("connectivity_votes", [])
            positive = sum(1 for v in votes if v.get("can_reach_vm", False))
            total = len(votes)

            if total > 0 and positive / total >= CONNECTIVITY_THRESHOLD:
                self.store("connectivity_verified", True)
                self.transition_to(WitnessAttestationState.MONITORING)
            else:
                self.store("connectivity_verified", False)
                # Vote to abort
                self.store("abort_reason", "vm_unreachable")
                self.transition_to(WitnessAttestationState.VOTING_ABORT)

        elif self.state == WitnessAttestationState.MONITORING:
            # Session is running, monitor for issues
            # Check for VM_CANCELLED
            cancellations = self.get_messages(AttestationMessageType.VM_CANCELLED)
            if cancellations:
                msg = cancellations[0]
                self.store("vm_cancelled_msg", msg.payload)
                self.store("actual_duration_seconds", msg.payload.get("actual_duration_seconds", 0))
                self.store("termination_reason", msg.payload.get("reason", "unknown"))
                self.clear_messages(AttestationMessageType.VM_CANCELLED)
                self.transition_to(WitnessAttestationState.ATTESTING)
                return outgoing

            # Check for misuse accusations
            misuse = self.get_messages(AttestationMessageType.MISUSE_ACCUSATION)
            if misuse:
                msg = misuse[0]
                self.store("misuse_accusation", msg.payload)
                self.clear_messages(AttestationMessageType.MISUSE_ACCUSATION)
                self.transition_to(WitnessAttestationState.HANDLING_MISUSE)

        elif self.state == WitnessAttestationState.HANDLING_MISUSE:
            # Investigate misuse accusation
            # For simulation, just check if evidence is provided
            accusation = self.load("misuse_accusation", {})
            evidence = accusation.get("evidence", "")

            if evidence:
                # Evidence provided - vote to abort with misuse reason
                self.store("abort_reason", "consumer_misuse")
                self.transition_to(WitnessAttestationState.VOTING_ABORT)
            else:
                # No evidence - return to monitoring
                self.transition_to(WitnessAttestationState.MONITORING)

        elif self.state == WitnessAttestationState.VOTING_ABORT:
            # Send abort vote to other witnesses
            abort_vote = {
                "session_id": self.load("session_id"),
                "witness": self.peer_id,
                "reason": self.load("abort_reason", "unknown"),
                "timestamp": current_time,
            }
            abort_vote["signature"] = sign(self.chain.private_key, hash_data(abort_vote))

            other_witnesses = self.load("other_witnesses", [])
            for witness in other_witnesses:
                outgoing.append(AttestationMessage(
                    msg_type=AttestationMessageType.ABORT_VOTE,
                    sender=self.peer_id,
                    payload=abort_vote,
                    timestamp=current_time,
                ))

            self.store("abort_votes", [abort_vote])
            self.store("abort_votes_sent_at", current_time)
            self.transition_to(WitnessAttestationState.COLLECTING_ABORT_VOTES)

        elif self.state == WitnessAttestationState.COLLECTING_ABORT_VOTES:
            # Collect abort votes
            votes = self.get_messages(AttestationMessageType.ABORT_VOTE)
            collected = self.load("abort_votes", [])

            for msg in votes:
                if msg.payload.get("witness") != self.peer_id:
                    collected.append(msg.payload)

            self.store("abort_votes", collected)
            self.clear_messages(AttestationMessageType.ABORT_VOTE)

            other_witnesses = self.load("other_witnesses", [])
            total_witnesses = len(other_witnesses) + 1

            if len(collected) >= total_witnesses:
                # All votes in - check if abort threshold met
                if len(collected) / total_witnesses >= ABORT_THRESHOLD:
                    self.store("session_aborted", True)
                    self.store("termination_reason", self.load("abort_reason"))
                    self.transition_to(WitnessAttestationState.ATTESTING)
                else:
                    # Not enough votes to abort - return to monitoring
                    self.transition_to(WitnessAttestationState.MONITORING)

            elif current_time - self.load("abort_votes_sent_at", 0) > ABORT_VOTE_TIMEOUT:
                if len(collected) / total_witnesses >= ABORT_THRESHOLD:
                    self.store("session_aborted", True)
                    self.store("termination_reason", self.load("abort_reason"))
                    self.transition_to(WitnessAttestationState.ATTESTING)
                else:
                    self.transition_to(WitnessAttestationState.MONITORING)

        elif self.state == WitnessAttestationState.ATTESTING:
            # Create attestation
            vm_allocated = self.load("vm_allocated_msg", {})
            vm_cancelled = self.load("vm_cancelled_msg", {})
            connectivity_votes = self.load("connectivity_votes", [])

            attestation = {
                "session_id": self.load("session_id"),
                "vm_allocated_hash": hash_data(vm_allocated) if vm_allocated else "",
                "vm_cancelled_hash": hash_data(vm_cancelled) if vm_cancelled else "",
                "connectivity_verified": self.load("connectivity_verified", False),
                "actual_duration_seconds": self.load("actual_duration_seconds", 0),
                "termination_reason": self.load("termination_reason", "unknown"),
                "cabal_votes": {v.get("witness", ""): v.get("can_reach_vm", False) for v in connectivity_votes},
                "cabal_signatures": [],
                "created_at": current_time,
            }

            my_sig = sign(self.chain.private_key, hash_data(attestation))
            attestation["cabal_signatures"] = [{"witness": self.peer_id, "signature": my_sig}]
            self.store("attestation", attestation)
            self.store("attestation_signatures", [{"witness": self.peer_id, "signature": my_sig}])

            # Share with other witnesses
            other_witnesses = self.load("other_witnesses", [])
            for witness in other_witnesses:
                outgoing.append(AttestationMessage(
                    msg_type=AttestationMessageType.ATTESTATION_SHARE,
                    sender=self.peer_id,
                    payload={"attestation": attestation},
                    timestamp=current_time,
                ))

            self.store("attestation_sent_at", current_time)
            self.transition_to(WitnessAttestationState.COLLECTING_ATTESTATION_SIGS)

        elif self.state == WitnessAttestationState.COLLECTING_ATTESTATION_SIGS:
            # Collect signatures from other witnesses
            shares = self.get_messages(AttestationMessageType.ATTESTATION_SHARE)
            sigs = self.load("attestation_signatures", [])

            for msg in shares:
                att = msg.payload.get("attestation", {})
                for sig_entry in att.get("cabal_signatures", []):
                    if sig_entry.get("witness") != self.peer_id:
                        if sig_entry not in sigs:
                            sigs.append(sig_entry)

            self.store("attestation_signatures", sigs)
            self.clear_messages(AttestationMessageType.ATTESTATION_SHARE)

            if len(sigs) >= ATTESTATION_THRESHOLD:
                self.transition_to(WitnessAttestationState.PROPAGATING_ATTESTATION)

        elif self.state == WitnessAttestationState.PROPAGATING_ATTESTATION:
            # Send attestation to consumer and provider
            attestation = self.load("attestation", {})
            sigs = self.load("attestation_signatures", [])
            attestation["cabal_signatures"] = sigs

            consumer = self.load("consumer")
            provider = self.load("provider")

            for recipient in [consumer, provider]:
                outgoing.append(AttestationMessage(
                    msg_type=AttestationMessageType.ATTESTATION_RESULT,
                    sender=self.peer_id,
                    payload=attestation,
                    timestamp=current_time,
                ))

            # Record on chain
            self.chain.append(
                BlockType.ATTESTATION,
                {
                    "session_id": attestation["session_id"],
                    "connectivity_verified": attestation["connectivity_verified"],
                    "actual_duration_seconds": attestation["actual_duration_seconds"],
                    "termination_reason": attestation["termination_reason"],
                    "witnesses": [s["witness"] for s in sigs],
                    "timestamp": current_time,
                },
                current_time,
            )

            self.transition_to(WitnessAttestationState.DONE)

        elif self.state == WitnessAttestationState.DONE:
            # Attestation complete
            pass

        return outgoing


# =============================================================================
# Consumer States for Attestation
# =============================================================================

class ConsumerAttestationState(Enum):
    """Consumer states during attestation phase."""
    WAITING_FOR_VM = auto()      # Waiting for VM to be ready
    CONNECTING = auto()          # Connecting to VM
    CONNECTED = auto()           # Using the VM
    REQUESTING_CANCEL = auto()   # Requesting session end
    SESSION_ENDED = auto()       # Session terminated


@dataclass
class ConsumerAttestationActor:
    """Consumer actor for attestation protocol (minimal role)."""
    peer_id: str
    chain: Chain
    current_time: float = 0.0

    state: ConsumerAttestationState = ConsumerAttestationState.WAITING_FOR_VM
    local_store: Dict[str, Any] = field(default_factory=dict)
    message_queue: List[AttestationMessage] = field(default_factory=list)

    def store(self, key: str, value: Any):
        self.local_store[key] = value

    def load(self, key: str, default: Any = None) -> Any:
        return self.local_store.get(key, default)

    def receive_message(self, msg: AttestationMessage):
        self.message_queue.append(msg)

    def get_messages(self, msg_type: AttestationMessageType = None) -> List[AttestationMessage]:
        if msg_type is None:
            return self.message_queue
        return [m for m in self.message_queue if m.msg_type == msg_type]

    def clear_messages(self, msg_type: AttestationMessageType = None):
        if msg_type is None:
            self.message_queue = []
        else:
            self.message_queue = [m for m in self.message_queue if m.msg_type != msg_type]

    def transition_to(self, new_state: ConsumerAttestationState):
        self.state = new_state

    def setup_session(self, session_id: str, provider: str):
        """Initialize consumer with session info."""
        self.store("session_id", session_id)
        self.store("provider", provider)

    def request_cancel(self):
        """Request to end the session early."""
        if self.state == ConsumerAttestationState.CONNECTED:
            self.transition_to(ConsumerAttestationState.REQUESTING_CANCEL)

    def tick(self, current_time: float) -> List[AttestationMessage]:
        """Process one tick of the consumer state machine."""
        self.current_time = current_time
        outgoing = []

        if self.state == ConsumerAttestationState.WAITING_FOR_VM:
            # Wait for VM_READY from provider
            ready_msgs = self.get_messages(AttestationMessageType.VM_READY)
            if ready_msgs:
                msg = ready_msgs[0]
                self.store("vm_info", msg.payload.get("vm_info", {}))
                self.clear_messages(AttestationMessageType.VM_READY)
                self.transition_to(ConsumerAttestationState.CONNECTING)

        elif self.state == ConsumerAttestationState.CONNECTING:
            # Simulate connection (instant for simulation)
            self.store("connected_at", current_time)
            self.transition_to(ConsumerAttestationState.CONNECTED)

        elif self.state == ConsumerAttestationState.CONNECTED:
            # Check for termination
            terminated = self.get_messages(AttestationMessageType.SESSION_TERMINATED)
            if terminated:
                msg = terminated[0]
                self.store("termination_reason", msg.payload.get("reason"))
                self.clear_messages(AttestationMessageType.SESSION_TERMINATED)
                self.transition_to(ConsumerAttestationState.SESSION_ENDED)

            # Check for attestation result
            attestations = self.get_messages(AttestationMessageType.ATTESTATION_RESULT)
            if attestations:
                msg = attestations[0]
                self.store("attestation", msg.payload)
                self.clear_messages(AttestationMessageType.ATTESTATION_RESULT)

        elif self.state == ConsumerAttestationState.REQUESTING_CANCEL:
            # Send cancel request to provider
            provider = self.load("provider")
            cancel_msg = {
                "session_id": self.load("session_id"),
                "consumer": self.peer_id,
                "timestamp": current_time,
            }
            cancel_msg["signature"] = sign(self.chain.private_key, hash_data(cancel_msg))

            outgoing.append(AttestationMessage(
                msg_type=AttestationMessageType.CANCEL_REQUEST,
                sender=self.peer_id,
                payload=cancel_msg,
                timestamp=current_time,
            ))

            self.transition_to(ConsumerAttestationState.CONNECTED)  # Wait for termination

        elif self.state == ConsumerAttestationState.SESSION_ENDED:
            # Check for attestation if not received yet
            attestations = self.get_messages(AttestationMessageType.ATTESTATION_RESULT)
            if attestations:
                msg = attestations[0]
                self.store("attestation", msg.payload)
                self.clear_messages(AttestationMessageType.ATTESTATION_RESULT)

        return outgoing


# =============================================================================
# Simulation Helper
# =============================================================================

class CabalAttestationSimulation:
    """
    Helper class to run cabal attestation simulations.

    Manages message passing between actors and time advancement.
    """

    def __init__(self):
        self.actors: Dict[str, Any] = {}
        self.current_time: float = 0.0
        self.message_log: List[AttestationMessage] = []

    def add_provider(self, actor: ProviderAttestationActor):
        self.actors[actor.peer_id] = actor

    def add_witness(self, actor: WitnessAttestationActor):
        self.actors[actor.peer_id] = actor

    def add_consumer(self, actor: ConsumerAttestationActor):
        self.actors[actor.peer_id] = actor

    def route_message(self, msg: AttestationMessage, recipient: str):
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

                # Route based on message type
                if msg.msg_type == AttestationMessageType.ATTESTATION_RESULT:
                    # Send to consumer and provider
                    for other_id, other_actor in self.actors.items():
                        if other_id != msg.sender:
                            if isinstance(other_actor, (ProviderAttestationActor, ConsumerAttestationActor)):
                                self.route_message(msg, other_id)
                elif msg.msg_type in (AttestationMessageType.VM_CONNECTIVITY_VOTE,
                                     AttestationMessageType.ABORT_VOTE,
                                     AttestationMessageType.ATTESTATION_SHARE):
                    # Send to witnesses (and provider for connectivity votes)
                    for other_id, other_actor in self.actors.items():
                        if other_id != msg.sender:
                            if isinstance(other_actor, WitnessAttestationActor):
                                self.route_message(msg, other_id)
                            elif isinstance(other_actor, ProviderAttestationActor) and \
                                 msg.msg_type == AttestationMessageType.VM_CONNECTIVITY_VOTE:
                                self.route_message(msg, other_id)
                elif msg.msg_type == AttestationMessageType.CANCEL_REQUEST:
                    # Send to provider
                    for other_id, other_actor in self.actors.items():
                        if isinstance(other_actor, ProviderAttestationActor):
                            self.route_message(msg, other_id)
                elif msg.msg_type in (AttestationMessageType.VM_ALLOCATED,
                                     AttestationMessageType.VM_CANCELLED,
                                     AttestationMessageType.MISUSE_ACCUSATION):
                    # Send to witnesses
                    for other_id, other_actor in self.actors.items():
                        if isinstance(other_actor, WitnessAttestationActor):
                            self.route_message(msg, other_id)
                elif msg.msg_type in (AttestationMessageType.VM_READY,
                                     AttestationMessageType.SESSION_TERMINATED):
                    # Send to consumer
                    for other_id, other_actor in self.actors.items():
                        if isinstance(other_actor, ConsumerAttestationActor):
                            self.route_message(msg, other_id)

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
                    if isinstance(actor, ProviderAttestationActor):
                        if actor.state not in (
                            ProviderAttestationState.WAITING_FOR_LOCK,
                            ProviderAttestationState.VM_RUNNING,
                            ProviderAttestationState.SESSION_COMPLETE,
                            ProviderAttestationState.SESSION_ABORTED,
                        ):
                            all_stable = False
                    elif isinstance(actor, WitnessAttestationActor):
                        if actor.state not in (
                            WitnessAttestationState.AWAITING_ALLOCATION,
                            WitnessAttestationState.MONITORING,
                            WitnessAttestationState.DONE,
                        ):
                            all_stable = False
                    elif isinstance(actor, ConsumerAttestationActor):
                        if actor.state not in (
                            ConsumerAttestationState.WAITING_FOR_VM,
                            ConsumerAttestationState.CONNECTED,
                            ConsumerAttestationState.SESSION_ENDED,
                        ):
                            all_stable = False

                if all_stable:
                    return tick_num + 1

        return max_ticks
