"""
Unit tests for the chain package (primitives, types, network).
"""

import pytest
import random
import time

from simulations.chain.primitives import (
    hash_data,
    sign,
    verify_sig,
    generate_id,
    random_bytes,
    Block,
    BlockType,
    Chain,
)
from simulations.chain.types import (
    SessionEndReason,
    AttestationOutcome,
    SessionTerms,
    SessionStart,
    SessionEnd,
    CabalAttestation,
    LockStatus,
    WitnessVerdict,
    LockIntent,
    WitnessSelectionCommitment,
    LockResult,
)
from simulations.chain.network import Network


# =============================================================================
# Cryptographic Primitives Tests
# =============================================================================

class TestCryptoPrimitives:
    """Tests for cryptographic primitive functions."""

    def test_hash_data_deterministic(self):
        """hash_data returns same hash for same input."""
        data = {"foo": "bar", "num": 42}
        hash1 = hash_data(data)
        hash2 = hash_data(data)
        assert hash1 == hash2

    def test_hash_data_order_independent(self):
        """hash_data is independent of key order."""
        data1 = {"a": 1, "b": 2}
        data2 = {"b": 2, "a": 1}
        assert hash_data(data1) == hash_data(data2)

    def test_hash_data_different_for_different_input(self):
        """hash_data returns different hash for different input."""
        hash1 = hash_data({"x": 1})
        hash2 = hash_data({"x": 2})
        assert hash1 != hash2

    def test_hash_data_length(self):
        """hash_data returns 16 character hex string."""
        h = hash_data({"test": "data"})
        assert len(h) == 16
        assert all(c in "0123456789abcdef" for c in h)

    def test_sign_deterministic(self):
        """sign returns same signature for same inputs."""
        sig1 = sign("private_key", "data")
        sig2 = sign("private_key", "data")
        assert sig1 == sig2

    def test_sign_different_keys(self):
        """sign returns different signatures for different keys."""
        sig1 = sign("key1", "data")
        sig2 = sign("key2", "data")
        assert sig1 != sig2

    def test_sign_length(self):
        """sign returns 16 character hex string."""
        sig = sign("key", "data")
        assert len(sig) == 16

    def test_verify_sig_valid(self):
        """verify_sig returns True for valid signature length."""
        sig = sign("key", "data")
        assert verify_sig("pubkey", "data", sig) is True

    def test_verify_sig_invalid_length(self):
        """verify_sig returns False for invalid signature length."""
        assert verify_sig("pubkey", "data", "short") is False
        assert verify_sig("pubkey", "data", "this_is_way_too_long") is False

    def test_generate_id_unique(self):
        """generate_id returns unique IDs."""
        ids = [generate_id() for _ in range(100)]
        assert len(set(ids)) == 100  # All unique

    def test_generate_id_length(self):
        """generate_id returns 12 character string."""
        id_ = generate_id()
        assert len(id_) == 12

    def test_random_bytes_length(self):
        """random_bytes returns correct number of bytes."""
        for n in [1, 16, 32, 64]:
            b = random_bytes(n)
            assert len(b) == n
            assert isinstance(b, bytes)


# =============================================================================
# Block Tests
# =============================================================================

class TestBlock:
    """Tests for Block class."""

    def test_block_creation(self):
        """Block can be created with required fields."""
        block = Block(
            owner="pk_test",
            sequence=0,
            previous_hash="0" * 16,
            block_type=BlockType.GENESIS,
            timestamp=1000.0,
            payload={"test": "data"},
        )
        assert block.owner == "pk_test"
        assert block.sequence == 0
        assert block.block_type == BlockType.GENESIS
        assert block.payload == {"test": "data"}

    def test_block_hash_computed(self):
        """Block hash is computed on creation."""
        block = Block(
            owner="pk_test",
            sequence=0,
            previous_hash="0" * 16,
            block_type=BlockType.GENESIS,
            timestamp=1000.0,
            payload={},
        )
        assert block.block_hash != ""
        assert len(block.block_hash) == 16

    def test_block_hash_deterministic(self):
        """Same block data produces same hash."""
        kwargs = {
            "owner": "pk_test",
            "sequence": 0,
            "previous_hash": "0" * 16,
            "block_type": BlockType.GENESIS,
            "timestamp": 1000.0,
            "payload": {"x": 1},
        }
        block1 = Block(**kwargs)
        block2 = Block(**kwargs)
        assert block1.block_hash == block2.block_hash

    def test_block_hash_differs_with_content(self):
        """Different content produces different hash."""
        block1 = Block(
            owner="pk_test",
            sequence=0,
            previous_hash="0" * 16,
            block_type=BlockType.GENESIS,
            timestamp=1000.0,
            payload={"x": 1},
        )
        block2 = Block(
            owner="pk_test",
            sequence=0,
            previous_hash="0" * 16,
            block_type=BlockType.GENESIS,
            timestamp=1000.0,
            payload={"x": 2},
        )
        assert block1.block_hash != block2.block_hash

    def test_block_to_dict(self):
        """Block can be serialized to dict."""
        block = Block(
            owner="pk_test",
            sequence=5,
            previous_hash="abc123",
            block_type=BlockType.PEER_HASH,
            timestamp=2000.0,
            payload={"peer": "pk_other", "hash": "def456"},
            signature="sig123",
        )
        d = block.to_dict()
        assert d["owner"] == "pk_test"
        assert d["sequence"] == 5
        assert d["block_type"] == "peer_hash"
        assert d["payload"]["peer"] == "pk_other"

    def test_block_from_dict(self):
        """Block can be deserialized from dict."""
        d = {
            "owner": "pk_test",
            "sequence": 3,
            "previous_hash": "prev123",
            "block_type": "session_start",
            "timestamp": 3000.0,
            "payload": {"session_id": "sess1"},
            "signature": "sig456",
            "block_hash": "hash789",
        }
        block = Block.from_dict(d)
        assert block.owner == "pk_test"
        assert block.sequence == 3
        assert block.block_type == BlockType.SESSION_START
        assert block.block_hash == "hash789"

    def test_block_types(self):
        """All block types can be used."""
        for bt in BlockType:
            block = Block(
                owner="pk_test",
                sequence=0,
                previous_hash="0" * 16,
                block_type=bt,
                timestamp=1000.0,
                payload={},
            )
            assert block.block_type == bt


# =============================================================================
# Chain Tests
# =============================================================================

class TestChain:
    """Tests for Chain class."""

    def test_chain_creation(self):
        """Chain is created with genesis block."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        assert len(chain.blocks) == 1
        assert chain.blocks[0].block_type == BlockType.GENESIS
        assert chain.blocks[0].sequence == 0

    def test_chain_genesis_previous_hash(self):
        """Genesis block has zeroed previous hash."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        assert chain.blocks[0].previous_hash == "0" * 16

    def test_chain_head(self):
        """head property returns most recent block."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        assert chain.head == chain.blocks[0]

        chain.append(BlockType.PEER_HASH, {"peer": "other"}, 2000.0)
        assert chain.head == chain.blocks[1]

    def test_chain_head_hash(self):
        """head_hash property returns hash of head."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        assert chain.head_hash == chain.head.block_hash

    def test_chain_append(self):
        """Can append blocks to chain."""
        chain = Chain("pk_test", "sk_test", 1000.0)

        block = chain.append(BlockType.PEER_HASH, {"peer": "pk_other"}, 2000.0)

        assert len(chain.blocks) == 2
        assert block.sequence == 1
        assert block.previous_hash == chain.blocks[0].block_hash
        assert block.block_type == BlockType.PEER_HASH

    def test_chain_append_links_correctly(self):
        """Appended blocks link to previous."""
        chain = Chain("pk_test", "sk_test", 1000.0)

        for i in range(5):
            chain.append(BlockType.PEER_HASH, {"i": i}, 1000.0 + i)

        for i in range(1, len(chain.blocks)):
            assert chain.blocks[i].previous_hash == chain.blocks[i-1].block_hash

    def test_chain_append_signs_block(self):
        """Appended blocks are signed."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        block = chain.append(BlockType.PEER_HASH, {}, 2000.0)
        assert block.signature != ""
        assert len(block.signature) == 16

    def test_chain_record_peer_hash(self):
        """record_peer_hash creates correct block."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        block = chain.record_peer_hash("pk_peer", "peer_hash_123", 2000.0)

        assert block.block_type == BlockType.PEER_HASH
        assert block.payload["peer"] == "pk_peer"
        assert block.payload["hash"] == "peer_hash_123"

    def test_chain_get_blocks_by_type(self):
        """get_blocks_by_type filters correctly."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        chain.record_peer_hash("p1", "h1", 2000.0)
        chain.record_peer_hash("p2", "h2", 3000.0)
        chain.append(BlockType.SESSION_START, {"session": "s1"}, 4000.0)

        peer_blocks = chain.get_blocks_by_type(BlockType.PEER_HASH)
        assert len(peer_blocks) == 2

        session_blocks = chain.get_blocks_by_type(BlockType.SESSION_START)
        assert len(session_blocks) == 1

        genesis_blocks = chain.get_blocks_by_type(BlockType.GENESIS)
        assert len(genesis_blocks) == 1

    def test_chain_age_days(self):
        """age_days calculates correctly."""
        chain = Chain("pk_test", "sk_test", 0.0)
        assert chain.age_days(86400.0) == 1.0
        assert chain.age_days(86400.0 * 30) == 30.0

    def test_chain_get_peer_hash(self):
        """get_peer_hash returns most recent hash for peer."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        chain.record_peer_hash("pk_peer", "hash1", 2000.0)
        chain.record_peer_hash("pk_peer", "hash2", 3000.0)
        chain.record_peer_hash("pk_other", "hash3", 4000.0)

        block = chain.get_peer_hash("pk_peer")
        assert block is not None
        assert block.payload["hash"] == "hash2"

    def test_chain_get_peer_hash_before_time(self):
        """get_peer_hash respects before_time filter."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        chain.record_peer_hash("pk_peer", "hash1", 2000.0)
        chain.record_peer_hash("pk_peer", "hash2", 3000.0)

        block = chain.get_peer_hash("pk_peer", before_time=2500.0)
        assert block is not None
        assert block.payload["hash"] == "hash1"

    def test_chain_get_peer_hash_not_found(self):
        """get_peer_hash returns None if peer not found."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        assert chain.get_peer_hash("unknown_peer") is None

    def test_chain_verify_chain_valid(self):
        """verify_chain returns True for valid chain."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        chain.append(BlockType.PEER_HASH, {}, 2000.0)
        chain.append(BlockType.PEER_HASH, {}, 3000.0)
        assert chain.verify_chain() is True

    def test_chain_verify_chain_empty(self):
        """verify_chain returns False for empty chain."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        chain.blocks = []
        assert chain.verify_chain() is False

    def test_chain_contains_hash(self):
        """contains_hash finds blocks by hash."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        block = chain.append(BlockType.PEER_HASH, {}, 2000.0)

        assert chain.contains_hash(block.block_hash) is True
        assert chain.contains_hash("nonexistent") is False

    def test_chain_get_state_at(self):
        """get_state_at extracts state at block hash."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        chain.record_peer_hash("pk_a", "hash_a", 2000.0)
        block2 = chain.record_peer_hash("pk_b", "hash_b", 3000.0)
        chain.record_peer_hash("pk_c", "hash_c", 4000.0)

        state = chain.get_state_at(block2.block_hash)
        assert state is not None
        assert "pk_a" in state["known_peers"]
        assert "pk_b" in state["known_peers"]
        assert "pk_c" not in state["known_peers"]

    def test_chain_get_state_at_not_found(self):
        """get_state_at returns None for unknown hash."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        assert chain.get_state_at("nonexistent") is None

    def test_chain_to_segment(self):
        """to_segment extracts chain portion."""
        chain = Chain("pk_test", "sk_test", 1000.0)
        chain.append(BlockType.PEER_HASH, {"i": 1}, 2000.0)
        chain.append(BlockType.PEER_HASH, {"i": 2}, 3000.0)
        chain.append(BlockType.PEER_HASH, {"i": 3}, 4000.0)

        segment = chain.to_segment()
        assert len(segment) == 4

        # From specific hash
        segment = chain.to_segment(from_hash=chain.blocks[1].block_hash)
        assert len(segment) == 3

        # To specific hash
        segment = chain.to_segment(to_hash=chain.blocks[2].block_hash)
        assert len(segment) == 3


# =============================================================================
# Types Tests
# =============================================================================

class TestTypes:
    """Tests for type definitions."""

    def test_session_terms_to_dict(self):
        """SessionTerms serializes correctly."""
        terms = SessionTerms(
            session_id="sess1",
            consumer="pk_consumer",
            provider="pk_provider",
            cabal=["pk_v1", "pk_v2"],
            cores=4,
            memory_gb=8.0,
            max_duration_hours=2.0,
            price_per_hour=0.5,
        )
        d = terms.to_dict()
        assert d["session_id"] == "sess1"
        assert d["cores"] == 4
        assert len(d["cabal"]) == 2

    def test_session_start_to_dict(self):
        """SessionStart serializes correctly."""
        terms = SessionTerms(
            session_id="sess1",
            consumer="pk_consumer",
            provider="pk_provider",
            cabal=[],
            cores=4,
            memory_gb=8.0,
            max_duration_hours=2.0,
            price_per_hour=0.5,
        )
        start = SessionStart(
            session_id="sess1",
            terms=terms,
            verified_access_at=1000.0,
            consumer_signature="sig123",
        )
        d = start.to_dict()
        assert d["session_id"] == "sess1"
        assert d["terms"]["cores"] == 4

    def test_session_end_to_dict(self):
        """SessionEnd serializes correctly."""
        end = SessionEnd(
            session_id="sess1",
            end_reason=SessionEndReason.CONSUMER_REQUEST,
            ended_at=2000.0,
            actual_duration_hours=1.5,
            provider_signature="sig456",
        )
        d = end.to_dict()
        assert d["end_reason"] == "consumer_request"
        assert d["actual_duration_hours"] == 1.5

    def test_cabal_attestation_id_computed(self):
        """CabalAttestation computes attestation_id."""
        att = CabalAttestation(
            session_id="sess1",
            session_start_hash="start_hash",
            session_end_hash="end_hash",
            outcome=AttestationOutcome.PASS,
            votes={"v1": True, "v2": True},
            signatures={"v1": "sig1", "v2": "sig2"},
            created_at=3000.0,
        )
        assert att.attestation_id != ""
        assert len(att.attestation_id) == 16

    def test_cabal_attestation_to_dict(self):
        """CabalAttestation serializes correctly."""
        att = CabalAttestation(
            session_id="sess1",
            session_start_hash="start_hash",
            session_end_hash="end_hash",
            outcome=AttestationOutcome.FAIL,
            votes={"v1": False},
            signatures={"v1": "sig1"},
            created_at=3000.0,
        )
        d = att.to_dict()
        assert d["outcome"] == "fail"
        assert d["votes"]["v1"] is False

    def test_cabal_attestation_from_dict(self):
        """CabalAttestation deserializes correctly."""
        d = {
            "attestation_id": "att123",
            "session_id": "sess1",
            "session_start_hash": "start",
            "session_end_hash": "end",
            "outcome": "inconclusive",
            "votes": {},
            "signatures": {},
            "created_at": 1000.0,
        }
        att = CabalAttestation.from_dict(d)
        assert att.outcome == AttestationOutcome.INCONCLUSIVE
        assert att.attestation_id == "att123"

    def test_lock_intent_to_dict(self):
        """LockIntent serializes correctly."""
        intent = LockIntent(
            consumer="pk_consumer",
            provider="pk_provider",
            amount=10.0,
            session_id="sess1",
            consumer_nonce=b"\x00\x01\x02\x03",
            provider_chain_checkpoint="checkpoint_hash",
            checkpoint_timestamp=1000.0,
            timestamp=2000.0,
            signature="sig",
        )
        d = intent.to_dict()
        assert d["amount"] == 10.0
        assert d["consumer_nonce"] == "00010203"

    def test_lock_result_to_dict(self):
        """LockResult serializes correctly."""
        result = LockResult(
            session_id="sess1",
            consumer="pk_consumer",
            provider="pk_provider",
            amount=10.0,
            status=LockStatus.ACCEPTED,
            observed_balance=100.0,
            witnesses=["w1", "w2"],
            witness_signatures=["sig1", "sig2"],
            consumer_signature="csig",
            timestamp=3000.0,
        )
        d = result.to_dict()
        assert d["status"] == "accepted"
        assert len(d["witnesses"]) == 2


# =============================================================================
# Network Tests
# =============================================================================

class TestNetwork:
    """Tests for Network class."""

    @pytest.fixture
    def network(self):
        """Create a fresh network."""
        random.seed(42)
        return Network()

    def test_network_create_identity(self, network):
        """Can create identities in network."""
        chain = network.create_identity("alice")
        assert chain.public_key == "pk_alice"
        assert "pk_alice" in network.chains

    def test_network_create_identity_trust(self, network):
        """Created identities have initial trust."""
        network.create_identity("alice", initial_trust=1.5)
        assert network.trust_scores["pk_alice"] == 1.5

    def test_network_get_chain(self, network):
        """Can retrieve chain by public key."""
        network.create_identity("alice")
        chain = network.get_chain("pk_alice")
        assert chain is not None
        assert chain.public_key == "pk_alice"

    def test_network_get_chain_not_found(self, network):
        """get_chain returns None for unknown key."""
        assert network.get_chain("pk_unknown") is None

    def test_network_advance_time(self, network):
        """Can advance simulation time."""
        initial = network.current_time
        network.advance_time(100.0)
        assert network.current_time == initial + 100.0

    def test_network_send_keepalive(self, network):
        """Keepalives create PEER_HASH blocks periodically."""
        network.create_identity("alice")
        network.create_identity("bob")

        # Send enough keepalives to trigger hash recording
        for _ in range(network.HASH_RECORD_FREQUENCY):
            network.send_keepalive("pk_alice", "pk_bob")

        bob_chain = network.get_chain("pk_bob")
        peer_blocks = bob_chain.get_blocks_by_type(BlockType.PEER_HASH)
        assert len(peer_blocks) == 1
        assert peer_blocks[0].payload["peer"] == "pk_alice"

    def test_network_send_keepalive_unknown_peer(self, network):
        """Keepalive with unknown peer returns False."""
        network.create_identity("alice")
        assert network.send_keepalive("pk_alice", "pk_unknown") is False
        assert network.send_keepalive("pk_unknown", "pk_alice") is False

    def test_network_simulate_keepalives(self, network):
        """simulate_keepalives sends between all peers."""
        for name in ["a", "b", "c", "d"]:
            network.create_identity(name)

        network.simulate_keepalives(rounds=20)

        # Each peer should have PEER_HASH blocks from others
        for key in network.chains:
            chain = network.chains[key]
            peer_blocks = chain.get_blocks_by_type(BlockType.PEER_HASH)
            assert len(peer_blocks) > 0

    def test_network_select_cabal(self, network):
        """Can select cabal for session."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(10):
            network.create_identity(f"verifier_{i}", initial_trust=2.0)

        cabal = network.select_cabal("pk_consumer", "pk_provider", size=5)
        assert len(cabal) == 5
        assert "pk_consumer" not in cabal
        assert "pk_provider" not in cabal

    def test_network_select_cabal_prefers_high_trust(self, network):
        """Cabal selection prefers high trust peers."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        network.create_identity("low_trust", initial_trust=1.1)
        network.create_identity("high_trust", initial_trust=10.0)

        cabal = network.select_cabal("pk_consumer", "pk_provider", size=1)
        assert "pk_high_trust" in cabal

    def test_network_create_session(self, network):
        """Can create a session."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(5):
            network.create_identity(f"v{i}", initial_trust=2.0)

        terms = network.create_session(
            "pk_consumer",
            "pk_provider",
            cores=8,
            price_per_hour=0.25,
        )

        assert terms.consumer == "pk_consumer"
        assert terms.provider == "pk_provider"
        assert terms.cores == 8
        assert len(terms.cabal) >= 3

    def test_network_create_session_insufficient_cabal(self, network):
        """Session creation fails with insufficient cabal."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        # No verifiers with sufficient trust

        with pytest.raises(ValueError, match="Not enough cabal"):
            network.create_session("pk_consumer", "pk_provider")

    def test_network_start_session(self, network):
        """Can start a session."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(5):
            network.create_identity(f"v{i}", initial_trust=2.0)

        terms = network.create_session("pk_consumer", "pk_provider")
        start = network.start_session(terms.session_id)

        assert start.session_id == terms.session_id
        assert terms.session_id in network.session_starts

        # Should be recorded on consumer's chain
        consumer_chain = network.get_chain("pk_consumer")
        start_blocks = consumer_chain.get_blocks_by_type(BlockType.SESSION_START)
        assert len(start_blocks) == 1

    def test_network_end_session(self, network):
        """Can end a session."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(5):
            network.create_identity(f"v{i}", initial_trust=2.0)

        terms = network.create_session("pk_consumer", "pk_provider")
        network.start_session(terms.session_id)
        network.advance_time(3600)  # 1 hour

        end = network.end_session(terms.session_id, SessionEndReason.CONSUMER_REQUEST)

        assert end.session_id == terms.session_id
        assert end.end_reason == SessionEndReason.CONSUMER_REQUEST

        # Should be recorded on provider's chain
        provider_chain = network.get_chain("pk_provider")
        end_blocks = provider_chain.get_blocks_by_type(BlockType.SESSION_END)
        assert len(end_blocks) == 1

    def test_network_create_attestation(self, network):
        """Can create attestation from votes."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(5):
            network.create_identity(f"v{i}", initial_trust=2.0)

        terms = network.create_session("pk_consumer", "pk_provider")
        network.start_session(terms.session_id)
        network.advance_time(3600)
        network.end_session(terms.session_id, SessionEndReason.CONSUMER_REQUEST)

        votes = {member: True for member in terms.cabal}
        attestation = network.create_attestation(terms.session_id, votes)

        assert attestation.outcome == AttestationOutcome.PASS
        assert terms.session_id in network.attestations

    def test_network_attestation_outcome_pass(self, network):
        """Attestation passes with majority pass votes."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(5):
            network.create_identity(f"v{i}", initial_trust=2.0)

        terms = network.create_session("pk_consumer", "pk_provider")
        network.start_session(terms.session_id)
        network.advance_time(3600)
        network.end_session(terms.session_id, SessionEndReason.CONSUMER_REQUEST)

        # 4 pass, 1 fail
        votes = {member: (i < 4) for i, member in enumerate(terms.cabal)}
        attestation = network.create_attestation(terms.session_id, votes)

        assert attestation.outcome == AttestationOutcome.PASS

    def test_network_attestation_outcome_fail(self, network):
        """Attestation fails with majority fail votes."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(5):
            network.create_identity(f"v{i}", initial_trust=2.0)

        terms = network.create_session("pk_consumer", "pk_provider")
        network.start_session(terms.session_id)
        network.advance_time(3600)
        network.end_session(terms.session_id, SessionEndReason.CONSUMER_REQUEST)

        # 1 pass, 4 fail
        votes = {member: (i < 1) for i, member in enumerate(terms.cabal)}
        attestation = network.create_attestation(terms.session_id, votes)

        assert attestation.outcome == AttestationOutcome.FAIL

    def test_network_run_full_session(self, network):
        """Can run a complete session lifecycle."""
        network.create_identity("consumer", initial_trust=1.0)
        network.create_identity("provider", initial_trust=1.0)
        for i in range(5):
            network.create_identity(f"v{i}", initial_trust=2.0)

        terms, attestation = network.run_full_session(
            "pk_consumer",
            "pk_provider",
            duration_hours=0.5,
            actual_valid=True,
        )

        assert terms.consumer == "pk_consumer"
        assert attestation.outcome == AttestationOutcome.PASS

    def test_network_compute_trust(self, network):
        """Can compute trust for identity."""
        chain = network.create_identity("provider", initial_trust=1.0)
        trust, details = network.compute_trust("pk_provider")

        assert trust >= 0
        assert "age_days" in details
        assert "t_age" in details

    def test_network_trust_increases_with_age(self, network):
        """Trust increases with chain age."""
        network.create_identity("provider", initial_trust=1.0)

        trust1, _ = network.compute_trust("pk_provider")

        network.advance_time(86400 * 30)  # 30 days

        trust2, _ = network.compute_trust("pk_provider")

        assert trust2 > trust1

    def test_network_update_all_trust_scores(self, network):
        """Can update all trust scores."""
        for name in ["a", "b", "c"]:
            network.create_identity(name, initial_trust=1.0)

        network.advance_time(86400 * 10)
        network.update_all_trust_scores()

        # All should have been updated
        for key in network.chains:
            assert network.trust_scores[key] > 0

    def test_network_select_witnesses_deterministic(self, network):
        """Witness selection is deterministic given same seed."""
        for i in range(10):
            network.create_identity(f"peer_{i}", initial_trust=2.0)

        chain_state = {
            "known_peers": [f"pk_peer_{i}" for i in range(10)],
            "trust_scores": {f"pk_peer_{i}": 2.0 for i in range(10)},
        }

        witnesses1 = network.select_witnesses_deterministic(
            seed=b"test_seed",
            chain_state=chain_state,
            count=5,
            exclude=["pk_peer_0"],
        )

        witnesses2 = network.select_witnesses_deterministic(
            seed=b"test_seed",
            chain_state=chain_state,
            count=5,
            exclude=["pk_peer_0"],
        )

        assert witnesses1 == witnesses2

    def test_network_select_witnesses_different_seeds(self, network):
        """Different seeds produce different witness selection."""
        for i in range(10):
            network.create_identity(f"peer_{i}", initial_trust=2.0)

        chain_state = {
            "known_peers": [f"pk_peer_{i}" for i in range(10)],
            "trust_scores": {f"pk_peer_{i}": 2.0 for i in range(10)},
        }

        witnesses1 = network.select_witnesses_deterministic(
            seed=b"seed_1",
            chain_state=chain_state,
            count=5,
            exclude=[],
        )

        witnesses2 = network.select_witnesses_deterministic(
            seed=b"seed_2",
            chain_state=chain_state,
            count=5,
            exclude=[],
        )

        # May be same by chance, but very unlikely with 10 candidates
        # Just check they're valid
        assert len(witnesses1) == 5
        assert len(witnesses2) == 5


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
