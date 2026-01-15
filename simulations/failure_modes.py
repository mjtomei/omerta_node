#!/usr/bin/env python3
"""
Trust Network Failure Modes Simulation

Comprehensive testing of attack vectors in human trust networks.
Measures damage potential, detection, and prevention effectiveness.
"""

import math
import random
from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple, Optional
from collections import defaultdict
import statistics

# Import base simulation
from trust_simulation import (
    Network, Identity, Transaction, Assertion,
    K_PAYMENT, BASE_CREDIT, TAU_TRANSACTION, TAU_ASSERTION,
    LARGE_THRESHOLD, IMMEDIATE_RELEASE_FRACTION, BASE_DELAY,
    NEW_OBSERVER_DISCOUNT, TRANSITIVITY_DECAY
)


@dataclass
class AttackResult:
    """Results of an attack simulation."""
    name: str
    attacker_profit: float  # Net gain for attacker (trust or payment)
    victim_damage: float    # Trust lost by victim(s)
    network_damage: float   # Total damage to network
    detection_day: int      # When attack was detectable (-1 if never)
    recovery_days: int      # Days for victim to recover (-1 if never)
    success: bool           # Did attacker achieve their goal?
    notes: str = ""


def compute_network_value(net: Network) -> float:
    """Compute total network trust value."""
    return sum(i.trust for i in net.identities.values())


def run_baseline(days: int = 180) -> Tuple[Network, float]:
    """Run baseline honest network for comparison."""
    net = Network()

    # Create providers and consumers
    for i in range(5):
        net.create_identity(f"provider{i}")
    for i in range(3):
        net.create_identity(f"consumer{i}")

    # Normal operation
    for day in range(days):
        net.advance_days(1)
        for provider in [f"provider{i}" for i in range(5)]:
            if random.random() < 0.3:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.95)

    net.solve_trust()
    baseline_value = compute_network_value(net)
    return net, baseline_value


# =============================================================================
# FAILURE MODE 1: Long Con / Exit Scam
# =============================================================================

def attack_long_con(trust_building_days: int = 180,
                    exploitation_days: int = 30,
                    exploitation_intensity: float = 0.8) -> AttackResult:
    """
    Attacker builds trust legitimately, then exploits it maximally.

    Real-world examples:
    - Ponzi schemes (Madoff)
    - Trusted employee embezzlement
    - Reputation-based fraud

    WITH DELAYED ESCROW: Large transactions have 50% held back for 1-7 days,
    which can be clawed back if consumers report fraud quickly.
    """
    net = Network()

    # Setup
    net.create_identity("attacker")
    net.create_identity("honest_provider")
    for i in range(3):
        net.create_identity(f"consumer{i}")

    # Phase 1: Build trust honestly
    for day in range(trust_building_days):
        net.advance_days(1)
        for provider in ["attacker", "honest_provider"]:
            if random.random() < 0.3:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.95)

    net.solve_trust()
    attacker_trust_before = net.identities["attacker"].trust
    payment_before = 1 - 1 / (1 + K_PAYMENT * attacker_trust_before)

    # Compute escrow delay for attacker
    escrow_delay = net.compute_escrow_delay(attacker_trust_before, 100)

    # Phase 2: Exploit - but with delayed escrow!
    exploitation_revenue = 0
    escrowed_funds = 0  # Funds held in escrow
    clawed_back = 0     # Funds recovered due to early detection

    failed_txs = []  # Track when failures happen

    for day in range(exploitation_days):
        net.advance_days(1)

        if random.random() < exploitation_intensity:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            tx_value = 3.0 * 8.0 * payment_before

            # Take payment but fail to deliver
            net.add_transaction(consumer, "attacker",
                              resource_weight=3.0,  # High value
                              duration_hours=8.0,
                              verification_score=0.1)  # Fail!

            # WITH ESCROW: Only immediate release is certain
            immediate = tx_value * IMMEDIATE_RELEASE_FRACTION
            delayed = tx_value * (1 - IMMEDIATE_RELEASE_FRACTION)

            exploitation_revenue += immediate
            escrowed_funds += delayed
            failed_txs.append(day)

        # Consumers complain - THIS CAN CLAW BACK ESCROWED FUNDS
        if random.random() < 0.5:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            net.add_assertion(consumer, "attacker",
                            score=-0.8,
                            classification="VERIFICATION_FAILURE")

            # If complaint comes within escrow window, funds are clawed back
            # Check if any recent transactions are still in escrow
            for tx_day in failed_txs:
                if day - tx_day < escrow_delay:
                    # This transaction's escrow can be clawed back
                    claw_amount = 3.0 * 8.0 * payment_before * (1 - IMMEDIATE_RELEASE_FRACTION)
                    clawed_back += claw_amount
                    escrowed_funds -= claw_amount

    # Final revenue = immediate + (escrowed - clawed_back)
    final_revenue = exploitation_revenue + max(0, escrowed_funds - clawed_back)

    net.solve_trust()
    attacker_trust_after = net.identities["attacker"].trust
    payment_after = 1 - 1 / (1 + K_PAYMENT * attacker_trust_after)

    # Calculate damage
    trust_lost = attacker_trust_before - attacker_trust_after
    consumer_damage = sum(net.identities[f"consumer{i}"].trust for i in range(3))

    # Detection: when did trust drop below 50% of peak?
    detection_day = -1
    if attacker_trust_after < attacker_trust_before * 0.5:
        detection_day = trust_building_days + 10  # Rough estimate

    return AttackResult(
        name="Long Con / Exit Scam",
        attacker_profit=final_revenue - trust_lost * 10,  # Value trust at 10x
        victim_damage=consumer_damage,
        network_damage=trust_lost,
        detection_day=detection_day,
        recovery_days=-1,  # Attacker doesn't recover
        success=final_revenue > trust_lost * 5,
        notes=f"Trust: {attacker_trust_before:.1f} -> {attacker_trust_after:.1f}, "
              f"Escrow delay: {escrow_delay}d, Clawed back: {clawed_back:.1f}"
    )


# =============================================================================
# FAILURE MODE 2: Reputation Laundering
# =============================================================================

def attack_reputation_laundering() -> AttackResult:
    """
    Bad actor burns identity, transfers assets to new identity,
    gets allies to vouch for new identity.

    Real-world examples:
    - Corporate rebranding after scandal
    - Criminals creating new identities

    WITH TRANSFER BURNS: Attempting to transfer coins from burned identity
    to new identity incurs massive burn rate due to low trust.
    """
    net = Network()

    # Create bad actor and their ally
    net.create_identity("bad_actor_v1")
    net.create_identity("ally")
    for i in range(3):
        net.create_identity(f"consumer{i}")

    # Build initial reputation and accumulate coins
    for day in range(90):
        net.advance_days(1)
        if random.random() < 0.3:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            net.add_transaction(consumer, "bad_actor_v1",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)
            # Simulate earning coins
            net.identities["bad_actor_v1"].coin_balance += 2.0 * 4.0 * 0.5
        if random.random() < 0.2:
            net.add_transaction(random.choice([f"consumer{i}" for i in range(3)]),
                              "ally",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

    net.solve_trust()
    v1_trust_peak = net.identities["bad_actor_v1"].trust
    v1_coins_peak = net.identities["bad_actor_v1"].coin_balance

    # Exploit and burn v1 identity
    for day in range(30):
        net.advance_days(1)
        if random.random() < 0.5:
            net.add_transaction(random.choice([f"consumer{i}" for i in range(3)]),
                              "bad_actor_v1",
                              resource_weight=3.0,
                              duration_hours=8.0,
                              verification_score=0.1)
            # Still extracting some value
            net.identities["bad_actor_v1"].coin_balance += 3.0 * 8.0 * 0.3

    net.solve_trust()
    v1_trust_after = net.identities["bad_actor_v1"].trust
    v1_coins_after = net.identities["bad_actor_v1"].coin_balance

    # Create new identity
    net.create_identity("bad_actor_v2")

    # TRY TO TRANSFER COINS FROM V1 TO V2
    # With transfer burns, this should fail badly
    transfer_amount = v1_coins_after
    received, burned = net.transfer_coins("bad_actor_v1", "bad_actor_v2", transfer_amount)
    burn_rate = burned / transfer_amount if transfer_amount > 0 else 1.0

    # Ally vouches for new identity
    net.add_assertion("ally", "bad_actor_v2",
                     score=0.8,
                     classification="EXCELLENT_SERVICE")

    # Try to build trust on v2
    for day in range(60):
        net.advance_days(1)
        if random.random() < 0.3:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            net.add_transaction(consumer, "bad_actor_v2",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

    net.solve_trust()
    v2_trust = net.identities["bad_actor_v2"].trust
    v2_coins = net.identities["bad_actor_v2"].coin_balance

    # Compare: did laundering work?
    # Success = v2 got significant trust AND kept significant assets
    laundering_success = v2_trust > v1_trust_peak * 0.3 and received > transfer_amount * 0.3

    return AttackResult(
        name="Reputation Laundering",
        attacker_profit=v2_trust + received,  # Trust + coins kept
        victim_damage=0,  # Victims from v1 already accounted for
        network_damage=v1_trust_peak - v1_trust_after + burned,  # Trust lost + coins burned
        detection_day=-1 if laundering_success else 90,  # Hard to detect
        recovery_days=60 if laundering_success else -1,
        success=laundering_success,
        notes=f"v1 peak: {v1_trust_peak:.1f}, v1 after: {v1_trust_after:.1f}, v2: {v2_trust:.1f}, "
              f"Transfer: {transfer_amount:.0f} -> {received:.0f} ({burn_rate*100:.0f}% burned)"
    )


# =============================================================================
# FAILURE MODE 3: Coordinated Character Assassination
# =============================================================================

def attack_character_assassination(num_attackers: int = 5) -> AttackResult:
    """
    Coordinated campaign to destroy honest provider's reputation.

    Real-world examples:
    - Competitor-funded negative reviews
    - Political smear campaigns
    - Online harassment mobs
    """
    net = Network()

    # Create victim and attackers
    net.create_identity("victim")
    for i in range(num_attackers):
        net.create_identity(f"attacker{i}")
    for i in range(3):
        net.create_identity(f"consumer{i}")

    # Build initial reputation for all
    for day in range(90):
        net.advance_days(1)
        # Victim does good work
        if random.random() < 0.4:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            net.add_transaction(consumer, "victim",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

        # Attackers also do some work to build credibility
        for i in range(num_attackers):
            if random.random() < 0.2:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, f"attacker{i}",
                                  resource_weight=1.0,
                                  duration_hours=2.0,
                                  verification_score=0.9)

    net.solve_trust()
    victim_trust_before = net.identities["victim"].trust
    attacker_trust_before = [net.identities[f"attacker{i}"].trust
                            for i in range(num_attackers)]

    # Coordinated attack
    for day in range(30):
        net.advance_days(1)

        # All attackers make false accusations
        for i in range(num_attackers):
            if random.random() < 0.3:
                net.add_assertion(f"attacker{i}", "victim",
                                score=-0.7,
                                classification="RESOURCE_MISMATCH",
                                has_evidence=False)

        # Victim continues good work
        if random.random() < 0.4:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            net.add_transaction(consumer, "victim",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

    net.solve_trust()
    victim_trust_after = net.identities["victim"].trust
    attacker_trust_after = [net.identities[f"attacker{i}"].trust
                           for i in range(num_attackers)]

    # Calculate results
    victim_damage = victim_trust_before - victim_trust_after
    attacker_damage = sum(b - a for b, a in
                         zip(attacker_trust_before, attacker_trust_after))

    # Success = victim lost significant trust
    attack_success = victim_damage > victim_trust_before * 0.2

    return AttackResult(
        name="Character Assassination",
        attacker_profit=-attacker_damage,  # Attackers lose trust
        victim_damage=victim_damage,
        network_damage=victim_damage + attacker_damage,
        detection_day=90 if attacker_damage > victim_damage else -1,
        recovery_days=30 if not attack_success else 90,
        success=attack_success,
        notes=f"Victim: {victim_trust_before:.1f} -> {victim_trust_after:.1f}, "
              f"Attackers lost avg: {attacker_damage/num_attackers:.1f}"
    )


# =============================================================================
# FAILURE MODE 4: Authority Capture
# =============================================================================

def attack_authority_capture() -> AttackResult:
    """
    Corrupt a high-trust node to influence the network.

    Real-world examples:
    - Bribing officials
    - Compromising trusted auditors
    - Social engineering influencers
    """
    net = Network()

    # Create authority (high-trust node) and target
    net.create_identity("authority")
    net.create_identity("target")  # Who authority will falsely endorse
    net.create_identity("honest_competitor")
    for i in range(5):
        net.create_identity(f"consumer{i}")

    # Build authority's reputation (long history)
    for day in range(180):
        net.advance_days(1)
        # Authority does lots of good work
        if random.random() < 0.5:
            consumer = random.choice([f"consumer{i}" for i in range(5)])
            net.add_transaction(consumer, "authority",
                              resource_weight=3.0,
                              duration_hours=8.0,
                              verification_score=0.98)

        # Others build some reputation
        for provider in ["target", "honest_competitor"]:
            if random.random() < 0.2:
                consumer = random.choice([f"consumer{i}" for i in range(5)])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.9)

    net.solve_trust()
    authority_trust = net.identities["authority"].trust
    target_trust_before = net.identities["target"].trust
    competitor_trust_before = net.identities["honest_competitor"].trust

    # Authority is compromised - makes false assertions
    # Endorses bad target, attacks honest competitor
    for day in range(30):
        net.advance_days(1)

        # False endorsement of target
        if random.random() < 0.3:
            net.add_assertion("authority", "target",
                            score=0.9,
                            classification="EXCELLENT_SERVICE")

        # False attack on competitor
        if random.random() < 0.2:
            net.add_assertion("authority", "honest_competitor",
                            score=-0.6,
                            classification="RESOURCE_MISMATCH",
                            has_evidence=False)

        # Target actually provides poor service
        if random.random() < 0.3:
            consumer = random.choice([f"consumer{i}" for i in range(5)])
            net.add_transaction(consumer, "target",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.4)  # Bad!

        # Competitor continues good service
        if random.random() < 0.3:
            consumer = random.choice([f"consumer{i}" for i in range(5)])
            net.add_transaction(consumer, "honest_competitor",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)

    net.solve_trust()
    authority_trust_after = net.identities["authority"].trust
    target_trust_after = net.identities["target"].trust
    competitor_trust_after = net.identities["honest_competitor"].trust

    # Calculate damage
    authority_damage = authority_trust - authority_trust_after
    target_boost = target_trust_after - target_trust_before
    competitor_damage = competitor_trust_before - competitor_trust_after

    return AttackResult(
        name="Authority Capture",
        attacker_profit=target_boost,
        victim_damage=competitor_damage,
        network_damage=authority_damage + competitor_damage,
        detection_day=180 + 20 if authority_damage > authority_trust * 0.1 else -1,
        recovery_days=60,
        success=target_boost > 0 and competitor_damage > 0,
        notes=f"Authority: {authority_trust:.1f} -> {authority_trust_after:.1f}, "
              f"Target boost: {target_boost:.1f}, Competitor damage: {competitor_damage:.1f}"
    )


# =============================================================================
# FAILURE MODE 5: Slow Degradation
# =============================================================================

def attack_slow_degradation() -> AttackResult:
    """
    Gradually reduce service quality while maintaining reputation.

    Real-world examples:
    - Enshittification
    - Quality fade in manufacturing
    - Regulatory capture

    WITH ACCUSATION-TRIGGERED VERIFICATION:
    - When consumers notice degradation, they file accusations
    - This increases verification rate
    - Earlier detection of quality decline
    """
    net = Network()

    # Create degrader
    net.create_identity("degrader")
    net.create_identity("honest")
    for i in range(3):
        net.create_identity(f"consumer{i}")

    # Build initial reputation with excellent service
    for day in range(90):
        net.advance_days(1)
        for provider in ["degrader", "honest"]:
            if random.random() < 0.3:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.98)

    net.solve_trust()
    degrader_trust_peak = net.identities["degrader"].trust
    honest_trust_baseline = net.identities["honest"].trust

    # Track when degradation is detected
    detection_phase = -1
    accusations_filed = 0

    # Gradually degrade
    for phase in range(6):  # 6 phases of degradation
        base_verification_score = 0.98 - (phase * 0.1)  # 0.98 -> 0.48

        # Get current verification rate (increases with accusations)
        current_verification_rate = net.get_verification_rate("degrader")

        for day in range(30):
            net.advance_days(1)

            # Degrader provides worse service each phase
            if random.random() < 0.3:
                consumer = random.choice([f"consumer{i}" for i in range(3)])

                # With higher verification rate, more likely to catch true score
                # Otherwise might slip through with artificially high score
                if random.random() < current_verification_rate:
                    # Verified - true score revealed
                    actual_score = base_verification_score
                else:
                    # Not verified - might appear better than reality
                    actual_score = min(base_verification_score + 0.2, 0.98)

                net.add_transaction(consumer, "degrader",
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=actual_score)

                # If consumer sees poor service, they might file accusation
                if actual_score < 0.8 and random.random() < 0.5:
                    accepted = net.add_assertion(consumer, "degrader",
                                               score=-0.5,
                                               classification="RESOURCE_MISMATCH",
                                               has_evidence=True)
                    if accepted:
                        accusations_filed += 1
                        if detection_phase == -1:
                            detection_phase = phase

            # Honest stays consistent
            if random.random() < 0.3:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, "honest",
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.98)

        # Update verification rate after each phase
        net.solve_trust()

    degrader_trust_after = net.identities["degrader"].trust
    honest_trust_after = net.identities["honest"].trust

    # Calculate: how much did degrader get away with?
    phases_before_detection = detection_phase if detection_phase >= 0 else 6

    return AttackResult(
        name="Slow Degradation",
        attacker_profit=phases_before_detection * 30,  # Days of extraction
        victim_damage=0,  # Consumers just got poor service
        network_damage=degrader_trust_peak - degrader_trust_after,
        detection_day=90 + phases_before_detection * 30 if detection_phase >= 0 else -1,
        recovery_days=-1,
        success=phases_before_detection >= 3,
        notes=f"Degrader: {degrader_trust_peak:.1f} -> {degrader_trust_after:.1f}, "
              f"Phases before detection: {phases_before_detection}"
    )


# =============================================================================
# FAILURE MODE 6: Sockpuppet Consensus Manufacturing
# =============================================================================

def attack_sockpuppet_consensus(num_sockpuppets: int = 10) -> AttackResult:
    """
    Create fake identities to manufacture appearance of consensus.

    Real-world examples:
    - Astroturfing
    - Fake review farms
    - Bot armies
    """
    net = Network()

    # Create sockpuppets and their master
    net.create_identity("master")
    for i in range(num_sockpuppets):
        net.create_identity(f"sock{i}")

    # Target to boost
    net.create_identity("target")
    net.create_identity("honest_competitor")

    # Consumers
    for i in range(3):
        net.create_identity(f"consumer{i}")

    # Age the sockpuppets (but minimal activity)
    for day in range(90):
        net.advance_days(1)

        # Sockpuppets do minimal transactions with each other
        if random.random() < 0.1:
            sock1 = random.choice([f"sock{i}" for i in range(num_sockpuppets)])
            sock2 = random.choice([f"sock{i}" for i in range(num_sockpuppets)])
            if sock1 != sock2:
                net.add_transaction(sock1, sock2,
                                  resource_weight=0.5,
                                  duration_hours=1.0,
                                  verification_score=1.0)

        # Real providers build reputation
        for provider in ["target", "honest_competitor"]:
            if random.random() < 0.2:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.9)

    net.solve_trust()
    target_before = net.identities["target"].trust
    competitor_before = net.identities["honest_competitor"].trust
    sock_trust = [net.identities[f"sock{i}"].trust for i in range(num_sockpuppets)]

    # Sockpuppets all endorse target
    for i in range(num_sockpuppets):
        net.add_assertion(f"sock{i}", "target",
                         score=0.9,
                         classification="EXCELLENT_SERVICE")

    # Sockpuppets attack competitor
    for i in range(num_sockpuppets):
        net.add_assertion(f"sock{i}", "honest_competitor",
                         score=-0.5,
                         classification="RESOURCE_MISMATCH",
                         has_evidence=False)

    net.solve_trust()
    target_after = net.identities["target"].trust
    competitor_after = net.identities["honest_competitor"].trust

    # Calculate impact
    target_boost = target_after - target_before
    competitor_damage = competitor_before - competitor_after

    # Check if sockpuppets were detected
    cluster_weights = net.detect_clusters()
    socks_detected = sum(1 for i in range(num_sockpuppets)
                        if cluster_weights.get(f"sock{i}", 1.0) < 1.0)

    return AttackResult(
        name="Sockpuppet Consensus",
        attacker_profit=target_boost,
        victim_damage=competitor_damage,
        network_damage=competitor_damage,
        detection_day=90 if socks_detected > num_sockpuppets * 0.5 else -1,
        recovery_days=30 if socks_detected > 0 else -1,
        success=target_boost > 1.0 or competitor_damage > 1.0,
        notes=f"Target boost: {target_boost:.1f}, Competitor damage: {competitor_damage:.1f}, "
              f"Socks detected: {socks_detected}/{num_sockpuppets}"
    )


# =============================================================================
# FAILURE MODE 7: Trust Arbitrage
# =============================================================================

def attack_trust_arbitrage() -> AttackResult:
    """
    Exploit trust differences between isolated communities.

    Real-world examples:
    - Selling counterfeit goods in new markets
    - Export of low-quality products
    - Regulatory arbitrage

    WITH LOCAL TRUST: Community B should see arbitrageur's trust as low
    because they have no transaction history with them.
    """
    net = Network()

    # Create two isolated communities
    for i in range(3):
        net.create_identity(f"community_a_{i}")
        net.create_identity(f"community_b_{i}")

    # Arbitrageur
    net.create_identity("arbitrageur")

    # Build reputation in community A
    for day in range(90):
        net.advance_days(1)

        # Intra-community transactions (communities stay isolated)
        for i in range(3):
            for j in range(3):
                if i != j and random.random() < 0.1:
                    net.add_transaction(f"community_a_{i}", f"community_a_{j}",
                                      resource_weight=2.0,
                                      duration_hours=4.0,
                                      verification_score=0.95)
                    net.add_transaction(f"community_b_{i}", f"community_b_{j}",
                                      resource_weight=2.0,
                                      duration_hours=4.0,
                                      verification_score=0.95)

        # Arbitrageur builds trust in community A (good service)
        if random.random() < 0.3:
            consumer = random.choice([f"community_a_{i}" for i in range(3)])
            net.add_transaction(consumer, "arbitrageur",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.98)

    net.solve_trust()
    arbitrageur_global_trust = net.identities["arbitrageur"].trust

    # Compute LOCAL trust as seen by community A vs community B
    edges = net.build_edge_weights()
    trust_from_a = net.compute_local_trust("arbitrageur", "community_a_0", edges)
    trust_from_b = net.compute_local_trust("arbitrageur", "community_b_0", edges)

    # With local trust, community B should see LOW trust (no path to arbitrageur)
    # They'd only give small jobs based on discounted global trust

    # Calculate max job size community B would accept
    # With local trust, they see: global_trust * 0.3 = ~6 instead of ~20
    local_payment_share = 1 - 1 / (1 + 0.1 * trust_from_b)

    # Attempt exploitation - but with LOCAL trust limiting job size
    exploitation_profit = 0
    jobs_accepted = 0
    jobs_rejected = 0

    for day in range(60):
        net.advance_days(1)

        if random.random() < 0.5:
            consumer = random.choice([f"community_b_{i}" for i in range(3)])

            # Community B uses LOCAL trust to decide job size
            local_trust_for_consumer = net.compute_local_trust("arbitrageur", consumer, edges)

            # Only accept large job if local trust is high enough
            if local_trust_for_consumer > 10:
                # Accept large job (this shouldn't happen with isolated communities)
                net.add_transaction(consumer, "arbitrageur",
                                  resource_weight=3.0,
                                  duration_hours=8.0,
                                  verification_score=0.3)
                exploitation_profit += 3.0 * 8.0 * local_payment_share
                jobs_accepted += 1
            else:
                # Reject or only accept tiny job
                jobs_rejected += 1
                # Maybe accept a small test job
                if local_trust_for_consumer > 2:
                    net.add_transaction(consumer, "arbitrageur",
                                      resource_weight=0.5,
                                      duration_hours=1.0,
                                      verification_score=0.3)
                    exploitation_profit += 0.5 * 1.0 * local_payment_share

    net.solve_trust()
    arbitrageur_trust_after = net.identities["arbitrageur"].trust

    # After bad service, even small trust is destroyed
    trust_from_b_after = net.compute_local_trust("arbitrageur", "community_b_0", edges)

    return AttackResult(
        name="Trust Arbitrage",
        attacker_profit=exploitation_profit,
        victim_damage=0,  # Limited damage due to local trust
        network_damage=arbitrageur_global_trust - arbitrageur_trust_after,
        detection_day=90 + 10,  # Quick detection through small test jobs
        recovery_days=60,
        success=jobs_accepted > 5,  # Success only if many large jobs accepted
        notes=f"Global: {arbitrageur_global_trust:.1f}, A sees: {trust_from_a:.1f}, "
              f"B sees: {trust_from_b:.1f}, Jobs accepted: {jobs_accepted}, rejected: {jobs_rejected}"
    )


# =============================================================================
# FAILURE MODE 8: Redemption Exploitation
# =============================================================================

def attack_redemption_exploitation(cycles: int = 3) -> AttackResult:
    """
    Repeatedly exploit forgiveness/recovery mechanisms.

    Real-world examples:
    - Serial fraudsters
    - Repeat offenders
    - "Reformed" con artists
    """
    net = Network()

    net.create_identity("exploiter")
    net.create_identity("honest")
    for i in range(3):
        net.create_identity(f"consumer{i}")

    total_exploitation = 0
    exploiter_trust_history = []

    for cycle in range(cycles):
        # Build trust
        for day in range(60):
            net.advance_days(1)
            for provider in ["exploiter", "honest"]:
                if random.random() < 0.3:
                    consumer = random.choice([f"consumer{i}" for i in range(3)])
                    net.add_transaction(consumer, provider,
                                      resource_weight=2.0,
                                      duration_hours=4.0,
                                      verification_score=0.95)

        net.solve_trust()
        trust_before = net.identities["exploiter"].trust
        exploiter_trust_history.append(("build", trust_before))

        # Exploit
        for day in range(20):
            net.advance_days(1)
            if random.random() < 0.6:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, "exploiter",
                                  resource_weight=3.0,
                                  duration_hours=8.0,
                                  verification_score=0.2)
                total_exploitation += 3.0 * 8.0 * 0.5

        net.solve_trust()
        trust_after = net.identities["exploiter"].trust
        exploiter_trust_history.append(("exploit", trust_after))

    net.solve_trust()
    final_trust = net.identities["exploiter"].trust
    honest_trust = net.identities["honest"].trust

    # Check if repeat offender is getting penalized more each time
    build_peaks = [t for label, t in exploiter_trust_history if label == "build"]
    declining_peaks = all(build_peaks[i] >= build_peaks[i+1]
                         for i in range(len(build_peaks)-1))

    return AttackResult(
        name="Redemption Exploitation",
        attacker_profit=total_exploitation,
        victim_damage=0,
        network_damage=build_peaks[0] - final_trust if build_peaks else 0,
        detection_day=60 * cycles,  # Detected after pattern emerges
        recovery_days=-1,
        success=not declining_peaks,  # Success if they can keep rebuilding
        notes=f"Cycles: {cycles}, Peaks: {[f'{t:.1f}' for t in build_peaks]}, "
              f"Final: {final_trust:.1f}"
    )


# =============================================================================
# FAILURE MODE 9: Manufactured Crisis
# =============================================================================

def attack_manufactured_crisis() -> AttackResult:
    """
    Create problem, then appear as savior to gain trust.

    Real-world examples:
    - Protection rackets
    - False flag operations
    - Vendor lock-in through FUD

    WITH NEW ACCUSATION RULES:
    - Attacker must have transaction history to accuse
    - Only one accusation per 90-day window
    - Victim gets increased verification, not immediate trust damage
    - If victim passes verification, attacker loses credibility
    """
    net = Network()

    net.create_identity("attacker")
    net.create_identity("victim_provider")
    net.create_identity("honest_helper")
    for i in range(3):
        net.create_identity(f"consumer{i}")

    # Initial state - everyone builds some trust
    for day in range(60):
        net.advance_days(1)
        for provider in ["attacker", "victim_provider", "honest_helper"]:
            if random.random() < 0.2:
                consumer = random.choice([f"consumer{i}" for i in range(3)])
                net.add_transaction(consumer, provider,
                                  resource_weight=2.0,
                                  duration_hours=4.0,
                                  verification_score=0.95)

    # Attacker needs to transact with victim to be able to accuse
    # This costs the attacker resources
    net.add_transaction("attacker", "victim_provider",
                       resource_weight=1.0,
                       duration_hours=1.0,
                       verification_score=0.95)

    net.solve_trust()
    attacker_trust_before = net.identities["attacker"].trust
    victim_trust_before = net.identities["victim_provider"].trust

    # Attacker tries to create crisis by making false accusations
    accusations_made = 0
    accusations_rejected = 0
    for day in range(15):
        net.advance_days(1)
        # Try to attack victim's reputation
        if random.random() < 0.4:
            accepted = net.add_assertion("attacker", "victim_provider",
                                        score=-0.7,
                                        classification="MALICIOUS_BEHAVIOR",
                                        has_evidence=False)
            if accepted:
                accusations_made += 1
            else:
                accusations_rejected += 1

    net.solve_trust()
    victim_trust_crisis = net.identities["victim_provider"].trust

    # Victim continues providing good service - passes verification
    verification_passes = 0
    for day in range(30):
        net.advance_days(1)

        # Victim continues good work (at increased verification rate)
        if random.random() < 0.3:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            net.add_transaction(consumer, "victim_provider",
                              resource_weight=2.0,
                              duration_hours=4.0,
                              verification_score=0.95)
            verification_passes += 1

        # Attacker tries to take business
        if random.random() < 0.3:
            consumer = random.choice([f"consumer{i}" for i in range(3)])
            net.add_transaction(consumer, "attacker",
                              resource_weight=3.0,
                              duration_hours=8.0,
                              verification_score=0.95)

    # Resolve pending accusations - victim passed verification
    if verification_passes >= 3:
        net.resolve_accusation("attacker", "victim_provider", verified_bad=False)

    net.solve_trust()
    attacker_trust_after = net.identities["attacker"].trust
    victim_trust_after = net.identities["victim_provider"].trust

    attacker_gain = attacker_trust_after - attacker_trust_before
    victim_loss = victim_trust_before - victim_trust_after

    return AttackResult(
        name="Manufactured Crisis",
        attacker_profit=attacker_gain,
        victim_damage=victim_loss,
        network_damage=victim_loss,
        detection_day=60 + 15 if victim_loss < 0 else -1,  # If attack failed
        recovery_days=30,
        success=attacker_gain > 10 and victim_loss > 0,  # Higher bar for success
        notes=f"Attacker: {attacker_trust_before:.1f} -> {attacker_trust_after:.1f}, "
              f"Victim: {victim_trust_before:.1f} -> {victim_trust_after:.1f}, "
              f"Accusations: {accusations_made} made, {accusations_rejected} rejected"
    )


# =============================================================================
# Run All Attacks and Summarize
# =============================================================================

def run_all_attacks():
    """Run all attack simulations and summarize results."""
    print("="*80)
    print("TRUST NETWORK FAILURE MODES SIMULATION")
    print("="*80)

    attacks = [
        ("Long Con / Exit Scam", attack_long_con),
        ("Reputation Laundering", attack_reputation_laundering),
        ("Character Assassination", attack_character_assassination),
        ("Authority Capture", attack_authority_capture),
        ("Slow Degradation", attack_slow_degradation),
        ("Sockpuppet Consensus", attack_sockpuppet_consensus),
        ("Trust Arbitrage", attack_trust_arbitrage),
        ("Redemption Exploitation", attack_redemption_exploitation),
        ("Manufactured Crisis", attack_manufactured_crisis),
    ]

    results = []
    for name, attack_fn in attacks:
        print(f"\n{'='*60}")
        print(f"ATTACK: {name}")
        print("="*60)

        # Run multiple times for statistical significance
        attack_results = []
        for i in range(5):
            random.seed(42 + i)
            result = attack_fn()
            attack_results.append(result)

        # Summarize
        avg_result = AttackResult(
            name=name,
            attacker_profit=statistics.mean(r.attacker_profit for r in attack_results),
            victim_damage=statistics.mean(r.victim_damage for r in attack_results),
            network_damage=statistics.mean(r.network_damage for r in attack_results),
            detection_day=int(statistics.mean(r.detection_day for r in attack_results if r.detection_day > 0)) if any(r.detection_day > 0 for r in attack_results) else -1,
            recovery_days=int(statistics.mean(r.recovery_days for r in attack_results if r.recovery_days > 0)) if any(r.recovery_days > 0 for r in attack_results) else -1,
            success=sum(r.success for r in attack_results) > len(attack_results) // 2,
            notes=attack_results[0].notes
        )

        results.append(avg_result)

        print(f"  Success rate: {sum(r.success for r in attack_results)}/{len(attack_results)}")
        print(f"  Avg attacker profit: {avg_result.attacker_profit:.1f}")
        print(f"  Avg victim damage: {avg_result.victim_damage:.1f}")
        print(f"  Avg network damage: {avg_result.network_damage:.1f}")
        print(f"  Detection day: {avg_result.detection_day}")
        print(f"  Recovery days: {avg_result.recovery_days}")
        print(f"  Notes: {avg_result.notes}")

    # Summary table
    print("\n" + "="*80)
    print("SUMMARY: Attack Effectiveness")
    print("="*80)
    print(f"{'Attack':<30} {'Success':<10} {'Profit':<12} {'Damage':<12} {'Detection':<12}")
    print("-"*80)

    for r in results:
        success_str = "YES" if r.success else "NO"
        detection_str = f"Day {r.detection_day}" if r.detection_day > 0 else "HARD"
        print(f"{r.name:<30} {success_str:<10} {r.attacker_profit:<12.1f} {r.network_damage:<12.1f} {detection_str:<12}")

    # Prevention recommendations
    print("\n" + "="*80)
    print("PREVENTION RECOMMENDATIONS")
    print("="*80)

    recommendations = {
        "Long Con / Exit Scam": [
            "Cap maximum payment share (never 100%)",
            "Escrow with delayed release for large transactions",
            "Require ongoing activity to maintain trust",
            "Track sudden behavior changes",
        ],
        "Reputation Laundering": [
            "Behavioral fingerprinting (transaction patterns)",
            "Asset flow tracking between identities",
            "Require substantial history for high trust",
            "Social graph analysis for connections",
        ],
        "Character Assassination": [
            "Require evidence for accusations",
            "Weight by accuser's direct experience with target",
            "Penalize coordinated accusation timing",
            "Let continued good work overcome accusations",
        ],
        "Authority Capture": [
            "No single identity should dominate trust graph",
            "Continuous verification even of trusted parties",
            "Detect sudden behavior changes in authorities",
            "Distribute authority among multiple parties",
        ],
        "Slow Degradation": [
            "Continuous verification sampling",
            "Compare current performance to historical baseline",
            "Weight recent transactions more heavily",
            "Statistical anomaly detection for quality trends",
        ],
        "Sockpuppet Consensus": [
            "Cluster detection for coordinated behavior",
            "Require transaction history for assertion credibility",
            "Behavioral similarity detection",
            "Graph analysis for isolated subgroups",
        ],
        "Trust Arbitrage": [
            "Cross-community reputation sharing",
            "Universal identity verification",
            "Geographic/community diversity requirements",
            "Delayed trust transfer between communities",
        ],
        "Redemption Exploitation": [
            "Escalating penalties for repeat offenders",
            "Permanent penalty residual",
            "Longer recovery periods each time",
            "Track pattern of trust drops",
        ],
        "Manufactured Crisis": [
            "Verify accusations before trust impact",
            "Detect benefit patterns (who gains from crisis)",
            "Require evidence for serious accusations",
            "Time-delay for major trust changes",
        ],
    }

    for attack, recs in recommendations.items():
        print(f"\n{attack}:")
        for rec in recs:
            print(f"  - {rec}")


if __name__ == "__main__":
    run_all_attacks()
