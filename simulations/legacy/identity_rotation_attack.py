#!/usr/bin/env python3
"""
Identity Rotation Attack Simulation

Simulates Attack Class 6: Identity Rotation / Spotlight Evasion
with and without the new defense mechanisms:
- Transfer burns (trust-based)
- Amount-based transfer burns
- Trust inheritance on transfer
- Circular flow detection

Key scenario: Wealthy user W is under scrutiny (low effective trust despite
high raw trust). W creates puppet P, invests time to build P's trust, then
transfers wealth to P to escape the spotlight.
"""

import math
from dataclasses import dataclass, field
from typing import Optional
import json

# Parameters
K_TRANSFER = 0.01  # Transfer burn curve scaling
K_AMOUNT = 0.15    # Amount-based burn scaling (moderate)
AMOUNT_SCALE = 10  # Log base for amount scaling
MEDIAN_BALANCE = 100  # Network median balance
CIRCULAR_THRESHOLD = 0.3
CIRCULAR_PENALTY_WEIGHT = 2.0


@dataclass
class Identity:
    name: str
    balance: float
    trust: float
    age_days: int = 0
    activity_invested: float = 0  # OMC equivalent of activity
    transfers_received: list = field(default_factory=list)
    transfers_sent: list = field(default_factory=list)

    def effective_trust(self, circular_penalty: float = 0) -> float:
        """Trust after penalties"""
        return self.trust / (1 + circular_penalty)


@dataclass
class Transfer:
    sender: str
    receiver: str
    amount: float
    day: int


class Simulation:
    def __init__(self, with_defenses: bool = True):
        self.with_defenses = with_defenses
        self.identities: dict[str, Identity] = {}
        self.all_transfers: list[Transfer] = []
        self.day = 0
        self.log: list[str] = []

    def create_identity(self, name: str, initial_balance: float = 0, initial_trust: float = 0):
        self.identities[name] = Identity(
            name=name,
            balance=initial_balance,
            trust=initial_trust,
            age_days=0
        )
        self.log.append(f"Day {self.day}: Created identity '{name}' with balance={initial_balance}, trust={initial_trust}")

    def advance_days(self, days: int):
        self.day += days
        for identity in self.identities.values():
            identity.age_days += days
        self.log.append(f"Day {self.day}: Advanced {days} days")

    def do_activity(self, name: str, omc_equivalent: float):
        """Identity does activity worth omc_equivalent in trust-building"""
        identity = self.identities[name]
        # Activity builds trust - simplified model
        trust_gain = omc_equivalent * 0.5  # 0.5 trust per OMC of activity
        identity.trust += trust_gain
        identity.activity_invested += omc_equivalent
        self.log.append(f"Day {self.day}: '{name}' did activity worth {omc_equivalent} OMC, gained {trust_gain:.1f} trust (now {identity.trust:.1f})")

    def transfer(self, sender_name: str, receiver_name: str, amount: float) -> float:
        """Execute transfer with burns and trust inheritance. Returns amount received."""
        sender = self.identities[sender_name]
        receiver = self.identities[receiver_name]

        if sender.balance < amount:
            self.log.append(f"Day {self.day}: FAILED transfer {sender_name} -> {receiver_name}: insufficient balance")
            return 0

        # Calculate burns
        trust_burn_rate = self._trust_burn_rate(sender.trust, receiver.trust)

        if self.with_defenses:
            amount_burn_rate = self._amount_burn_rate(amount)
            combined_burn_rate = min(1.0, trust_burn_rate + amount_burn_rate)
        else:
            amount_burn_rate = 0
            combined_burn_rate = trust_burn_rate

        amount_burned = amount * combined_burn_rate
        amount_received = amount - amount_burned

        # Execute transfer
        sender.balance -= amount
        receiver.balance += amount_received

        # Record transfer
        transfer = Transfer(sender_name, receiver_name, amount, self.day)
        self.all_transfers.append(transfer)
        sender.transfers_sent.append(transfer)
        receiver.transfers_received.append(transfer)

        self.log.append(
            f"Day {self.day}: Transfer {sender_name} -> {receiver_name}: "
            f"{amount:.0f} OMC sent, {amount_received:.0f} received "
            f"(trust_burn={trust_burn_rate:.1%}, amount_burn={amount_burn_rate:.1%}, total={combined_burn_rate:.1%})"
        )

        # Trust inheritance (only with defenses)
        if self.with_defenses:
            self._apply_trust_inheritance(sender, receiver, amount_received)

        return amount_received

    def _trust_burn_rate(self, sender_trust: float, receiver_trust: float) -> float:
        """Calculate trust-based burn rate"""
        min_trust = min(sender_trust, receiver_trust)
        return 1 / (1 + K_TRANSFER * min_trust)

    def _amount_burn_rate(self, amount: float) -> float:
        """Calculate amount-based burn rate"""
        amount_factor = amount / MEDIAN_BALANCE
        if amount_factor <= 1:
            return 0
        return K_AMOUNT * math.log(1 + amount_factor) / math.log(AMOUNT_SCALE)

    def _apply_trust_inheritance(self, sender: Identity, receiver: Identity, amount_received: float):
        """Apply trust inheritance - only decreases, never increases"""
        if amount_received <= 0:
            return

        balance_before = receiver.balance - amount_received
        balance_after = receiver.balance

        transfer_ratio = amount_received / balance_after

        # Blend trust
        blended_trust = transfer_ratio * sender.trust + (1 - transfer_ratio) * receiver.trust

        # Only decrease
        old_trust = receiver.trust
        receiver.trust = min(receiver.trust, blended_trust)

        if receiver.trust < old_trust:
            self.log.append(
                f"  -> Trust inheritance: {receiver.name}'s trust {old_trust:.1f} -> {receiver.trust:.1f} "
                f"(transfer_ratio={transfer_ratio:.1%}, sender_trust={sender.trust:.1f})"
            )

    def calculate_circular_flow(self, name: str) -> float:
        """Calculate circular flow ratio for an identity"""
        identity = self.identities[name]

        # Build simple cycle detection: A -> B -> A patterns
        sent_to = {t.receiver: t.amount for t in identity.transfers_sent}
        received_from = {t.sender: t.amount for t in identity.transfers_received}

        # Find circular flow (simplified: direct A <-> B cycles)
        circular_volume = 0
        for counterparty in set(sent_to.keys()) & set(received_from.keys()):
            circular_volume += min(sent_to[counterparty], received_from[counterparty])

        total_volume = sum(t.amount for t in identity.transfers_sent) + \
                       sum(t.amount for t in identity.transfers_received)

        if total_volume == 0:
            return 0

        return circular_volume / total_volume

    def get_circular_penalty(self, name: str) -> float:
        """Calculate circular flow penalty"""
        if not self.with_defenses:
            return 0
        ratio = self.calculate_circular_flow(name)
        if ratio > CIRCULAR_THRESHOLD:
            return (ratio - CIRCULAR_THRESHOLD) * CIRCULAR_PENALTY_WEIGHT
        return 0

    def status(self, name: str) -> dict:
        """Get current status of an identity"""
        identity = self.identities[name]
        circular_penalty = self.get_circular_penalty(name)
        return {
            "name": name,
            "balance": identity.balance,
            "trust": identity.trust,
            "effective_trust": identity.effective_trust(circular_penalty),
            "age_days": identity.age_days,
            "activity_invested": identity.activity_invested,
            "circular_ratio": self.calculate_circular_flow(name),
            "circular_penalty": circular_penalty
        }

    def summary(self) -> dict:
        """Get summary of all identities"""
        return {name: self.status(name) for name in self.identities}


def run_attack_scenario(with_defenses: bool) -> dict:
    """
    Run the identity rotation attack scenario.

    Key scenario:
    - W is wealthy and under scrutiny (effective trust reduced)
    - W invests time/resources to build puppet P with good trust
    - W transfers wealth to P to escape spotlight
    - Question: Does P inherit W's scrutiny?
    """

    sim = Simulation(with_defenses=with_defenses)

    print(f"\n{'='*60}")
    print(f"IDENTITY ROTATION ATTACK - {'WITH' if with_defenses else 'WITHOUT'} DEFENSES")
    print(f"{'='*60}\n")

    # Setup: Wealthy user W under scrutiny
    # W has high raw trust (500) but is under scrutiny, so for transfer purposes
    # we model their "effective trust for inheritance" as reduced
    W_RAW_TRUST = 500
    W_SCRUTINY_PENALTY = 0.8  # 80% reduction due to scrutiny
    W_EFFECTIVE_FOR_INHERITANCE = W_RAW_TRUST * (1 - W_SCRUTINY_PENALTY)  # = 100

    sim.create_identity("W", initial_balance=100000, initial_trust=W_EFFECTIVE_FOR_INHERITANCE)
    print(f"W: Wealthy user with 100,000 OMC")
    print(f"   Raw trust: {W_RAW_TRUST}, but under heavy scrutiny")
    print(f"   Effective trust (for inheritance): {W_EFFECTIVE_FOR_INHERITANCE}")

    # W creates and invests in puppet P over 18 months (significant investment)
    sim.create_identity("P", initial_balance=0, initial_trust=0)

    print("\nPHASE 1: Puppet Maturation (18 months of real activity)")
    print("-" * 40)

    # P does substantial activity - 50 OMC worth per month for 18 months
    for month in range(18):
        sim.advance_days(30)
        sim.do_activity("P", omc_equivalent=50)

    total_activity_cost = 18 * 50  # 900 OMC equivalent

    p_status = sim.status("P")
    print(f"After 18 months of substantial activity:")
    print(f"  P's trust: {p_status['trust']:.0f}")
    print(f"  P's balance: {p_status['balance']:.0f}")
    print(f"  Total investment: {total_activity_cost} OMC ({total_activity_cost/100000:.1%} of W's wealth)")
    print(f"  Time invested: 18 months")

    print("\nPHASE 2: Large Wealth Transfer")
    print("-" * 40)

    w_before = sim.status("W")
    p_before = sim.status("P")

    print(f"Before transfer:")
    print(f"  W: balance={w_before['balance']:.0f}, trust={w_before['trust']:.1f} (under scrutiny)")
    print(f"  P: balance={p_before['balance']:.0f}, trust={p_before['trust']:.1f} (clean reputation)")

    # Calculate expected burn rates for display
    min_trust = min(w_before['trust'], p_before['trust'])
    trust_burn = 1 / (1 + K_TRANSFER * min_trust)
    amount_factor = 50000 / MEDIAN_BALANCE
    amount_burn = K_AMOUNT * math.log(1 + amount_factor) / math.log(AMOUNT_SCALE) if with_defenses else 0

    print(f"\n  Transfer analysis for 50,000 OMC:")
    print(f"    Trust burn rate: {trust_burn:.1%} (based on min trust = {min_trust:.0f})")
    if with_defenses:
        print(f"    Amount burn rate: {amount_burn:.1%} (500× median balance)")
        print(f"    Combined burn rate: {min(1.0, trust_burn + amount_burn):.1%}")

    amount_received = sim.transfer("W", "P", 50000)

    w_after = sim.status("W")
    p_after = sim.status("P")

    print(f"\nAfter transfer:")
    print(f"  W: balance={w_after['balance']:.0f}")
    print(f"  P: balance={p_after['balance']:.0f}, trust={p_after['trust']:.1f}")
    print(f"  Amount burned: {50000 - amount_received:.0f} OMC ({(50000-amount_received)/50000:.1%})")

    if with_defenses and p_after['trust'] < p_before['trust']:
        print(f"\n  *** TRUST INHERITANCE APPLIED ***")
        print(f"  P's trust dropped: {p_before['trust']:.1f} -> {p_after['trust']:.1f}")
        print(f"  P now inherits W's scrutinized reputation!")

    print("\nPHASE 3: Wealth Cycling Attempt")
    print("-" * 40)

    if p_after['balance'] > 0:
        cycle_amount = min(10000, p_after['balance'])
        sim.advance_days(30)
        received = sim.transfer("P", "W", cycle_amount)

        p_final = sim.status("P")
        w_final = sim.status("W")

        print(f"P attempts to cycle {cycle_amount:.0f} OMC back to W:")
        print(f"  Amount received by W: {received:.0f}")
        print(f"  P's circular_ratio: {p_final['circular_ratio']:.2f}")
        if p_final['circular_penalty'] > 0:
            print(f"  P's circular_penalty: {p_final['circular_penalty']:.2f}")
            print(f"  P's effective_trust after penalty: {p_final['effective_trust']:.1f}")
    else:
        p_final = p_after
        w_final = w_after
        print("P has no balance to cycle back")

    print("\nFINAL ANALYSIS:")
    print("-" * 40)

    total_remaining = w_final['balance'] + p_final['balance']
    total_burned = 100000 - total_remaining

    print(f"  W: balance={w_final['balance']:.0f}")
    print(f"  P: balance={p_final['balance']:.0f}, trust={p_final['trust']:.1f}, effective={p_final['effective_trust']:.1f}")
    print(f"  Total wealth preserved: {total_remaining:.0f} ({total_remaining/100000:.1%})")
    print(f"  Total burned: {total_burned:.0f} ({total_burned/100000:.1%})")

    # Key question: Did P escape W's reputation?
    # Without defenses: P keeps their earned trust (450)
    # With defenses: P's trust is pulled down toward W's (100)
    spotlight_evaded = p_final['effective_trust'] > W_EFFECTIVE_FOR_INHERITANCE * 1.5  # P has significantly better rep than W

    print(f"\n  SPOTLIGHT EVADED? {spotlight_evaded}")
    print(f"    W's effective trust: {W_EFFECTIVE_FOR_INHERITANCE}")
    print(f"    P's effective trust: {p_final['effective_trust']:.1f}")
    if spotlight_evaded:
        print(f"    -> P successfully escaped W's reputation!")
    else:
        print(f"    -> P inherited W's scrutinized reputation")

    return {
        "defenses_enabled": with_defenses,
        "original_wealth": 100000,
        "final_wealth_w": w_final['balance'],
        "final_wealth_p": p_final['balance'],
        "total_wealth_preserved": total_remaining,
        "wealth_burned_pct": total_burned / 100000,
        "p_trust_before_transfer": p_before['trust'],
        "p_trust_after_transfer": p_final['trust'],
        "p_effective_trust_final": p_final['effective_trust'],
        "w_effective_trust": W_EFFECTIVE_FOR_INHERITANCE,
        "spotlight_evaded": spotlight_evaded,
        "activity_cost": total_activity_cost,
    }


def run_multi_puppet_scenario(with_defenses: bool) -> dict:
    """
    More sophisticated attack: W maintains multiple puppets as escape hatches.
    W invests significant time in each, then distributes wealth.
    """

    sim = Simulation(with_defenses=with_defenses)

    print(f"\n{'='*60}")
    print(f"MULTI-PUPPET ATTACK - {'WITH' if with_defenses else 'WITHOUT'} DEFENSES")
    print(f"{'='*60}\n")

    # W is under scrutiny (effective trust = 100)
    W_EFFECTIVE_TRUST = 100
    sim.create_identity("W", initial_balance=100000, initial_trust=W_EFFECTIVE_TRUST)
    print(f"W: 100,000 OMC, under scrutiny (effective trust = {W_EFFECTIVE_TRUST})")

    puppets = ["P1", "P2", "P3"]
    for p in puppets:
        sim.create_identity(p, initial_balance=0, initial_trust=0)

    print("\nPHASE 1: Parallel Puppet Maturation (12 months)")
    print("-" * 40)

    # Mature all puppets with substantial activity
    for month in range(12):
        sim.advance_days(30)
        for p in puppets:
            sim.do_activity(p, omc_equivalent=30)

    total_investment = 12 * 30 * 3
    puppet_trust = sim.status("P1")['trust']
    print(f"After 12 months, each puppet has trust ~{puppet_trust:.0f}")
    print(f"Total investment: {total_investment} OMC ({total_investment/100000:.1%} of W's wealth)")

    print("\nPHASE 2: Distribute Wealth Across Puppets")
    print("-" * 40)

    # W distributes wealth across puppets
    results = []
    for i, p in enumerate(puppets):
        before = sim.status(p)
        amount = 25000  # Distribute 75k total, keep 25k
        received = sim.transfer("W", p, amount)
        after = sim.status(p)
        results.append((p, amount, received, before['trust'], after['trust']))
        print(f"  W -> {p}: sent {amount}, received {received:.0f}")
        if after['trust'] < before['trust']:
            print(f"    Trust dropped: {before['trust']:.0f} -> {after['trust']:.0f} (inherited W's reputation)")

    print("\nPHASE 3: Puppet-to-Puppet Cycling")
    print("-" * 40)

    # Try to cycle between puppets (if they have balance)
    sim.advance_days(30)

    p1_bal = sim.status("P1")['balance']
    p2_bal = sim.status("P2")['balance']
    p3_bal = sim.status("P3")['balance']

    if p1_bal > 1000 and p2_bal > 1000 and p3_bal > 1000:
        print("Attempting P1 -> P2 -> P3 -> P1 cycle of 1000 OMC each:")
        r1 = sim.transfer("P1", "P2", 1000)
        r2 = sim.transfer("P2", "P3", 1000)
        r3 = sim.transfer("P3", "P1", 1000)
        print(f"  P1->P2: {r1:.0f}, P2->P3: {r2:.0f}, P3->P1: {r3:.0f}")
    else:
        print("Puppets have insufficient balance for cycling test")

    print("\nFINAL STATUS:")
    print("-" * 40)

    total_balance = sim.identities["W"].balance
    puppet_trusts = []
    for p in puppets:
        status = sim.status(p)
        total_balance += status['balance']
        puppet_trusts.append(status['effective_trust'])
        print(f"  {p}: balance={status['balance']:.0f}, trust={status['trust']:.1f}, "
              f"effective={status['effective_trust']:.1f}, circular={status['circular_ratio']:.2f}")

    w_status = sim.status("W")
    print(f"  W: balance={w_status['balance']:.0f}")

    total_burned = 100000 - total_balance
    print(f"\n  Total wealth preserved: {total_balance:.0f} ({total_balance/100000:.1%})")
    print(f"  Total burned: {total_burned:.0f} ({total_burned/100000:.1%})")

    max_puppet_trust = max(puppet_trusts) if puppet_trusts else 0
    spotlight_evaded = max_puppet_trust > W_EFFECTIVE_TRUST * 1.5

    print(f"\n  SPOTLIGHT EVADED? {spotlight_evaded}")
    print(f"    W's effective trust: {W_EFFECTIVE_TRUST}")
    print(f"    Best puppet trust: {max_puppet_trust:.1f}")

    return {
        "defenses_enabled": with_defenses,
        "total_wealth_preserved": total_balance,
        "wealth_burned_pct": total_burned / 100000,
        "best_puppet_effective_trust": max_puppet_trust,
        "w_effective_trust": W_EFFECTIVE_TRUST,
        "spotlight_evaded": spotlight_evaded,
    }


def main():
    print("\n" + "="*70)
    print("IDENTITY ROTATION ATTACK SIMULATION")
    print("Testing new defenses: trust inheritance, amount burns, circular flow")
    print("="*70)

    # Run single puppet scenario
    results_no_defense = run_attack_scenario(with_defenses=False)
    results_with_defense = run_attack_scenario(with_defenses=True)

    # Run multi-puppet scenario
    multi_no_defense = run_multi_puppet_scenario(with_defenses=False)
    multi_with_defense = run_multi_puppet_scenario(with_defenses=True)

    # Summary comparison
    print("\n" + "="*70)
    print("SUMMARY COMPARISON")
    print("="*70)

    print("\nSingle Puppet Attack:")
    print(f"  {'Metric':<35} {'No Defense':>15} {'With Defense':>15}")
    print(f"  {'-'*35} {'-'*15} {'-'*15}")
    print(f"  {'Wealth preserved (OMC)':.<35} {results_no_defense['total_wealth_preserved']:>15,.0f} {results_with_defense['total_wealth_preserved']:>15,.0f}")
    print(f"  {'Wealth burned':.<35} {results_no_defense['wealth_burned_pct']*100:>14.1f}% {results_with_defense['wealth_burned_pct']*100:>14.1f}%")
    print(f"  {'P trust before transfer':.<35} {results_no_defense['p_trust_before_transfer']:>15.0f} {results_with_defense['p_trust_before_transfer']:>15.0f}")
    print(f"  {'P trust after transfer':.<35} {results_no_defense['p_trust_after_transfer']:>15.0f} {results_with_defense['p_trust_after_transfer']:>15.0f}")
    print(f"  {'W effective trust':.<35} {results_no_defense['w_effective_trust']:>15.0f} {results_with_defense['w_effective_trust']:>15.0f}")
    print(f"  {'Spotlight evaded':.<35} {str(results_no_defense['spotlight_evaded']):>15} {str(results_with_defense['spotlight_evaded']):>15}")

    print("\nMulti-Puppet Attack:")
    print(f"  {'Metric':<35} {'No Defense':>15} {'With Defense':>15}")
    print(f"  {'-'*35} {'-'*15} {'-'*15}")
    print(f"  {'Wealth preserved (OMC)':.<35} {multi_no_defense['total_wealth_preserved']:>15,.0f} {multi_with_defense['total_wealth_preserved']:>15,.0f}")
    print(f"  {'Wealth burned':.<35} {multi_no_defense['wealth_burned_pct']*100:>14.1f}% {multi_with_defense['wealth_burned_pct']*100:>14.1f}%")
    print(f"  {'Best puppet trust':.<35} {multi_no_defense['best_puppet_effective_trust']:>15.1f} {multi_with_defense['best_puppet_effective_trust']:>15.1f}")
    print(f"  {'W effective trust':.<35} {multi_no_defense['w_effective_trust']:>15.0f} {multi_with_defense['w_effective_trust']:>15.0f}")
    print(f"  {'Spotlight evaded':.<35} {str(multi_no_defense['spotlight_evaded']):>15} {str(multi_with_defense['spotlight_evaded']):>15}")

    print("\n" + "="*70)
    print("KEY FINDINGS")
    print("="*70)

    # Calculate changes
    if results_no_defense['p_effective_trust_final'] > 0:
        trust_reduction = (1 - results_with_defense['p_effective_trust_final'] / results_no_defense['p_effective_trust_final']) * 100
    else:
        trust_reduction = 0

    print(f"""
1. TRUST INHERITANCE IS THE KEY DEFENSE
   - Without defenses: P keeps their earned trust ({results_no_defense['p_trust_after_transfer']:.0f})
   - With defenses: P's trust drops to match W's ({results_with_defense['p_trust_after_transfer']:.0f})
   - Trust reduction: {trust_reduction:.0f}%

2. THE SPOTLIGHT FOLLOWS THE MONEY
   - Without defenses: P has trust {results_no_defense['p_effective_trust_final']:.0f} vs W's {results_no_defense['w_effective_trust']:.0f} → EVADES SPOTLIGHT
   - With defenses: P has trust {results_with_defense['p_effective_trust_final']:.0f} vs W's {results_with_defense['w_effective_trust']:.0f} → SPOTLIGHT FOLLOWS

3. MULTI-PUPPET DOESN'T HELP
   - Each puppet that receives money inherits W's reputation
   - Distributing across multiple puppets just means multiple puppets with low trust

4. AMOUNT-BASED BURNS ADD ADDITIONAL COST
   - Large transfers (500× median) incur extra ~{K_AMOUNT * math.log(501) / math.log(AMOUNT_SCALE) * 100:.0f}% burn
   - Makes repeated rotation progressively more expensive
""")

    # Save results
    all_results = {
        "single_puppet": {
            "no_defense": results_no_defense,
            "with_defense": results_with_defense
        },
        "multi_puppet": {
            "no_defense": multi_no_defense,
            "with_defense": multi_with_defense
        }
    }

    with open("${OMERTA_DIR}/simulations/identity_rotation_results.json", "w") as f:
        json.dump(all_results, f, indent=2)

    print(f"\nResults saved to identity_rotation_results.json")


if __name__ == "__main__":
    main()
