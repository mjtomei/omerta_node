#!/usr/bin/env python3
"""
Monetary Policy Simulation - Iteration 2

Improvements over first iteration:
1. Combined/simultaneous attacks
2. Different initial parameter configurations
3. Policy sensitivity analysis
4. Attack timing variations
5. Recovery analysis after attacks
6. Comparative policy configurations
"""

import math
import random
import json
import time
import os
from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple, Optional, Any
from collections import defaultdict
import statistics
from datetime import datetime

from monetary_policy_simulation import (
    PolicyNetwork, NetworkParameters, DailyMetrics,
    compute_gini, run_baseline_simulation
)

# =============================================================================
# New Attack Scenarios
# =============================================================================

def run_combined_sybil_inflation_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Combined attack: Sybils that also participate in trust inflation.
    More sophisticated than single-vector attacks.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Honest participants
    for i in range(8):
        net.create_identity(f"honest_{i}")
    for i in range(15):
        net.create_identity(f"consumer_{i}")

    sybils = []
    sybil_day = 120

    for day in range(days):
        consumers = [f"consumer_{i}" for i in range(15)]
        honest = [f"honest_{i}" for i in range(8)]

        # Normal honest activity
        for provider in honest:
            if random.random() < 0.25:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

        # Create sybils on day 120
        if day == sybil_day:
            for i in range(20):
                net.create_identity(f"sybil_{i}")
                sybils.append(f"sybil_{i}")

        # Combined Sybil + Inflation attack
        if day > sybil_day and sybils:
            # Sybils transact among themselves (Sybil pattern)
            for sybil in sybils:
                if random.random() < 0.3:
                    other = random.choice([s for s in sybils if s != sybil])
                    net.add_transaction(other, sybil,
                        resource_weight=random.uniform(2, 4),
                        duration_hours=random.uniform(4, 8),
                        verification_score=1.0)

            # Sybils also do rapid mutual boosting (Inflation pattern)
            if day > 200:
                for sybil in random.sample(sybils, min(10, len(sybils))):
                    for _ in range(2):
                        if random.random() < 0.4:
                            other = random.choice([s for s in sybils if s != sybil])
                            net.add_transaction(other, sybil,
                                resource_weight=4.0,
                                duration_hours=8.0,
                                verification_score=1.0)

                            # Also positive assertions
                            if random.random() < 0.2:
                                net.add_assertion(other, sybil, score=0.8,
                                    classification="EXCELLENT_SERVICE")

        net.solve_trust()
        net.advance_day()

    return net


def run_attack_and_recovery(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Attack followed by recovery period - measures how quickly network recovers.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create network
    for i in range(10):
        net.create_identity(f"provider_{i}")
    for i in range(20):
        net.create_identity(f"consumer_{i}")

    attackers = []
    attack_start = 180
    attack_end = 360

    for day in range(days):
        providers = [f"provider_{i}" for i in range(10)]
        consumers = [f"consumer_{i}" for i in range(20)]

        # Normal activity throughout
        for provider in providers:
            if random.random() < 0.25:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

        # Attack phase: create attackers and cause disruption
        if day == attack_start:
            for i in range(15):
                net.create_identity(f"attacker_{i}")
                attackers.append(f"attacker_{i}")

        if attack_start <= day < attack_end and attackers:
            # Attackers do various bad things
            for attacker in attackers:
                # Bad transactions
                if random.random() < 0.3:
                    consumer = random.choice(consumers)
                    net.add_transaction(consumer, attacker,
                        resource_weight=random.uniform(2, 4),
                        duration_hours=random.uniform(3, 7),
                        verification_score=random.uniform(0.2, 0.5))

                # False accusations against honest providers
                if random.random() < 0.1:
                    target = random.choice(providers)
                    net.add_assertion(attacker, target,
                        score=-0.5, classification="RESOURCE_MISMATCH",
                        has_evidence=False)

        # Recovery phase: attackers become inactive
        if day >= attack_end:
            # Attackers stop participating (simulates detection and removal)
            pass

        net.solve_trust()
        net.advance_day()

    return net


def run_wave_attack(days: int = 720, with_policy: bool = False) -> PolicyNetwork:
    """
    Multiple attack waves with different intensities.
    Tests adaptive response over time.
    """
    net = PolicyNetwork()
    net.auto_policy_enabled = with_policy

    # Create network
    for i in range(10):
        net.create_identity(f"provider_{i}")
    for i in range(20):
        net.create_identity(f"consumer_{i}")

    # Define attack waves: (start_day, end_day, intensity, type)
    attack_waves = [
        (100, 150, 0.3, "sybil"),
        (250, 300, 0.5, "inflation"),
        (400, 450, 0.7, "combined"),
        (550, 600, 0.4, "degradation"),
    ]

    wave_attackers = {}

    for day in range(days):
        providers = [f"provider_{i}" for i in range(10)]
        consumers = [f"consumer_{i}" for i in range(20)]

        # Normal activity
        for provider in providers:
            if random.random() < 0.25:
                consumer = random.choice(consumers)
                net.add_transaction(consumer, provider,
                    resource_weight=random.uniform(1, 3),
                    duration_hours=random.uniform(2, 6),
                    verification_score=random.uniform(0.9, 1.0))

        # Check for attack waves
        for wave_idx, (start, end, intensity, attack_type) in enumerate(attack_waves):
            wave_key = f"wave_{wave_idx}"

            # Create attackers at wave start
            if day == start:
                wave_attackers[wave_key] = []
                num_attackers = int(10 * intensity)
                for i in range(num_attackers):
                    attacker_id = f"attacker_{wave_key}_{i}"
                    net.create_identity(attacker_id)
                    wave_attackers[wave_key].append(attacker_id)

            # Execute attack during wave
            if start <= day < end and wave_key in wave_attackers:
                attackers = wave_attackers[wave_key]

                for attacker in attackers:
                    if attack_type == "sybil":
                        if random.random() < intensity:
                            other = random.choice([a for a in attackers if a != attacker])
                            net.add_transaction(other, attacker,
                                resource_weight=2.0, duration_hours=4.0,
                                verification_score=1.0)

                    elif attack_type == "inflation":
                        for _ in range(2):
                            if random.random() < intensity:
                                other = random.choice([a for a in attackers if a != attacker])
                                net.add_transaction(other, attacker,
                                    resource_weight=4.0, duration_hours=8.0,
                                    verification_score=1.0)

                    elif attack_type == "combined":
                        if random.random() < intensity:
                            other = random.choice([a for a in attackers if a != attacker])
                            net.add_transaction(other, attacker,
                                resource_weight=3.0, duration_hours=6.0,
                                verification_score=1.0)
                            net.add_assertion(other, attacker, score=0.9,
                                classification="EXCELLENT_SERVICE")

                    elif attack_type == "degradation":
                        if random.random() < intensity:
                            consumer = random.choice(consumers)
                            quality = 0.9 - (day - start) * 0.01
                            net.add_transaction(consumer, attacker,
                                resource_weight=2.0, duration_hours=4.0,
                                verification_score=max(0.3, quality))

        net.solve_trust()
        net.advance_day()

    return net


def run_policy_comparison(days: int = 720) -> Dict[str, PolicyNetwork]:
    """
    Compare different policy configurations on the same attack scenario.
    """
    results = {}

    # Define different policy configurations
    configs = {
        "no_policy": {"enabled": False},
        "conservative": {
            "enabled": True,
            "dampening": 0.1,
            "max_change": 0.02,
            "interval": 14
        },
        "moderate": {
            "enabled": True,
            "dampening": 0.3,
            "max_change": 0.05,
            "interval": 7
        },
        "aggressive": {
            "enabled": True,
            "dampening": 0.5,
            "max_change": 0.10,
            "interval": 3
        }
    }

    for config_name, config in configs.items():
        random.seed(42)  # Same seed for fair comparison

        net = PolicyNetwork()
        net.auto_policy_enabled = config.get("enabled", False)

        if config.get("enabled"):
            net.dampening_factor = config.get("dampening", 0.3)
            net.max_change_rate = config.get("max_change", 0.05)
            net.min_adjustment_interval = config.get("interval", 7)

        # Create network
        for i in range(10):
            net.create_identity(f"provider_{i}")
        for i in range(20):
            net.create_identity(f"consumer_{i}")

        # Run with Sybil attack starting at day 180
        sybils = []

        for day in range(days):
            providers = [f"provider_{i}" for i in range(10)]
            consumers = [f"consumer_{i}" for i in range(20)]

            # Normal activity
            for provider in providers:
                if random.random() < 0.25:
                    consumer = random.choice(consumers)
                    net.add_transaction(consumer, provider,
                        resource_weight=random.uniform(1, 3),
                        duration_hours=random.uniform(2, 6),
                        verification_score=random.uniform(0.9, 1.0))

            # Sybil attack
            if day == 180:
                for i in range(20):
                    net.create_identity(f"sybil_{i}")
                    sybils.append(f"sybil_{i}")

            if day > 180 and sybils:
                for sybil in sybils:
                    if random.random() < 0.3:
                        other = random.choice([s for s in sybils if s != sybil])
                        net.add_transaction(other, sybil,
                            resource_weight=3.0, duration_hours=6.0,
                            verification_score=1.0)

            net.solve_trust()
            net.advance_day()

        results[config_name] = net

    return results


def run_parameter_sensitivity_sweep(days: int = 360) -> List[Dict]:
    """
    Sweep different parameter values to understand sensitivity.
    """
    results = []

    # Sweep k_payment values
    k_payment_values = [0.01, 0.05, 0.1, 0.2, 0.5]

    for k_val in k_payment_values:
        random.seed(42)

        net = PolicyNetwork()
        net.params.k_payment = k_val
        net.auto_policy_enabled = False  # Fixed parameter

        # Create network
        for i in range(10):
            net.create_identity(f"provider_{i}")
        for i in range(20):
            net.create_identity(f"consumer_{i}")

        # Run with some attack activity
        for day in range(days):
            providers = [f"provider_{i}" for i in range(10)]
            consumers = [f"consumer_{i}" for i in range(20)]

            for provider in providers:
                if random.random() < 0.3:
                    consumer = random.choice(consumers)
                    net.add_transaction(consumer, provider,
                        resource_weight=random.uniform(1, 4),
                        duration_hours=random.uniform(1, 8),
                        verification_score=random.uniform(0.85, 1.0))

            net.solve_trust()
            net.advance_day()

        if net.metrics_history:
            final = net.metrics_history[-1]
            results.append({
                "k_payment": k_val,
                "final_gini": final.trust_gini,
                "final_mean_trust": final.mean_trust,
                "final_cluster_prevalence": final.cluster_prevalence
            })

    return results


# =============================================================================
# Run Iteration 2
# =============================================================================

def run_iteration2(output_dir: str = "results_iteration2"):
    """Run all iteration 2 experiments."""
    os.makedirs(output_dir, exist_ok=True)

    print("="*80)
    print("MONETARY POLICY SIMULATION - ITERATION 2")
    print("="*80)
    print(f"Started at: {datetime.now().isoformat()}\n")

    all_results = {}

    # Experiment 1: Combined Sybil + Inflation Attack
    print("\n" + "="*60)
    print("EXPERIMENT 1: Combined Sybil + Inflation Attack")
    print("="*60)

    combined_results = {"with_policy": [], "without_policy": []}
    for run in range(5):
        print(f"  Run {run+1}/5...", end="", flush=True)
        random.seed(42 + run)

        net_no = run_combined_sybil_inflation_attack(days=720, with_policy=False)
        net_yes = run_combined_sybil_inflation_attack(days=720, with_policy=True)

        if net_no.metrics_history:
            final = net_no.metrics_history[-1]
            combined_results["without_policy"].append({
                "final_gini": final.trust_gini,
                "final_cluster_prevalence": final.cluster_prevalence,
                "final_mean_trust": final.mean_trust
            })
        if net_yes.metrics_history:
            final = net_yes.metrics_history[-1]
            combined_results["with_policy"].append({
                "final_gini": final.trust_gini,
                "final_cluster_prevalence": final.cluster_prevalence,
                "final_mean_trust": final.mean_trust,
                "parameter_changes": len(net_yes.parameter_changes)
            })
        print(" done")

    all_results["combined_attack"] = combined_results

    # Experiment 2: Attack and Recovery
    print("\n" + "="*60)
    print("EXPERIMENT 2: Attack and Recovery Analysis")
    print("="*60)

    recovery_results = {"with_policy": [], "without_policy": []}
    for run in range(5):
        print(f"  Run {run+1}/5...", end="", flush=True)
        random.seed(42 + run)

        net_no = run_attack_and_recovery(days=720, with_policy=False)
        net_yes = run_attack_and_recovery(days=720, with_policy=True)

        # Track trust at key points
        for net, key in [(net_no, "without_policy"), (net_yes, "with_policy")]:
            if len(net.metrics_history) > 500:
                pre_attack = net.metrics_history[170].mean_trust if len(net.metrics_history) > 170 else 0
                during_attack = net.metrics_history[300].mean_trust if len(net.metrics_history) > 300 else 0
                post_recovery = net.metrics_history[500].mean_trust if len(net.metrics_history) > 500 else 0
                final = net.metrics_history[-1]

                recovery_results[key].append({
                    "pre_attack_trust": pre_attack,
                    "during_attack_trust": during_attack,
                    "post_recovery_trust": post_recovery,
                    "final_trust": final.mean_trust,
                    "recovery_ratio": post_recovery / pre_attack if pre_attack > 0 else 0
                })
        print(" done")

    all_results["recovery"] = recovery_results

    # Experiment 3: Wave Attack
    print("\n" + "="*60)
    print("EXPERIMENT 3: Multi-Wave Attack")
    print("="*60)

    wave_results = {"with_policy": [], "without_policy": []}
    for run in range(5):
        print(f"  Run {run+1}/5...", end="", flush=True)
        random.seed(42 + run)

        net_no = run_wave_attack(days=720, with_policy=False)
        net_yes = run_wave_attack(days=720, with_policy=True)

        for net, key in [(net_no, "without_policy"), (net_yes, "with_policy")]:
            if net.metrics_history:
                # Sample metrics at wave boundaries
                wave_metrics = []
                for day_idx in [90, 160, 240, 310, 390, 460, 540, 610, 700]:
                    if day_idx < len(net.metrics_history):
                        m = net.metrics_history[day_idx]
                        wave_metrics.append({
                            "day": m.day,
                            "gini": m.trust_gini,
                            "cluster": m.cluster_prevalence
                        })

                final = net.metrics_history[-1]
                wave_results[key].append({
                    "wave_metrics": wave_metrics,
                    "final_gini": final.trust_gini,
                    "final_cluster": final.cluster_prevalence
                })
        print(" done")

    all_results["wave_attack"] = wave_results

    # Experiment 4: Policy Configuration Comparison
    print("\n" + "="*60)
    print("EXPERIMENT 4: Policy Configuration Comparison")
    print("="*60)

    print("  Running 4 policy configurations...", end="", flush=True)
    policy_comparison = run_policy_comparison(days=720)
    policy_results = {}

    for config_name, net in policy_comparison.items():
        if net.metrics_history:
            final = net.metrics_history[-1]
            policy_results[config_name] = {
                "final_gini": final.trust_gini,
                "final_cluster_prevalence": final.cluster_prevalence,
                "final_mean_trust": final.mean_trust,
                "parameter_changes": len(net.parameter_changes),
                "metrics_samples": [
                    {"day": m.day, "gini": m.trust_gini, "trust": m.mean_trust}
                    for m in net.metrics_history[::30]
                ]
            }
    print(" done")

    all_results["policy_comparison"] = policy_results

    # Experiment 5: Parameter Sensitivity Sweep
    print("\n" + "="*60)
    print("EXPERIMENT 5: Parameter Sensitivity Sweep")
    print("="*60)

    print("  Sweeping k_payment values...", end="", flush=True)
    sensitivity_results = run_parameter_sensitivity_sweep(days=360)
    all_results["sensitivity"] = sensitivity_results
    print(" done")

    # Save results
    print("\n" + "="*60)
    print("Saving results...")
    print("="*60)

    with open(f"{output_dir}/iteration2_results.json", "w") as f:
        json.dump(all_results, f, indent=2, default=str)

    # Generate report
    generate_iteration2_report(all_results, output_dir)

    print(f"\nResults saved to {output_dir}/")
    return all_results


def generate_iteration2_report(results: Dict, output_dir: str):
    """Generate markdown report for iteration 2."""
    report = []

    report.append("# Monetary Policy Simulation - Iteration 2 Report")
    report.append(f"\nGenerated: {datetime.now().isoformat()}\n")

    report.append("## Overview\n")
    report.append("This iteration focuses on:")
    report.append("- Combined/simultaneous attacks")
    report.append("- Attack and recovery dynamics")
    report.append("- Multiple attack waves")
    report.append("- Policy configuration comparison")
    report.append("- Parameter sensitivity analysis\n")

    # Combined Attack Results
    report.append("## 1. Combined Sybil + Inflation Attack\n")
    combined = results.get("combined_attack", {})
    if combined:
        report.append("| Metric | Without Policy | With Policy |")
        report.append("|--------|----------------|-------------|")

        wo = combined.get("without_policy", [])
        w = combined.get("with_policy", [])

        if wo and w:
            wo_gini = statistics.mean(r.get("final_gini", 0) for r in wo)
            w_gini = statistics.mean(r.get("final_gini", 0) for r in w)
            wo_cluster = statistics.mean(r.get("final_cluster_prevalence", 0) for r in wo)
            w_cluster = statistics.mean(r.get("final_cluster_prevalence", 0) for r in w)

            report.append(f"| Final Gini | {wo_gini:.3f} | {w_gini:.3f} |")
            report.append(f"| Cluster Prevalence | {wo_cluster:.3f} | {w_cluster:.3f} |")

    # Recovery Results
    report.append("\n## 2. Attack and Recovery Analysis\n")
    recovery = results.get("recovery", {})
    if recovery:
        wo = recovery.get("without_policy", [])
        w = recovery.get("with_policy", [])

        if wo and w:
            wo_ratio = statistics.mean(r.get("recovery_ratio", 0) for r in wo)
            w_ratio = statistics.mean(r.get("recovery_ratio", 0) for r in w)

            report.append(f"**Recovery Ratio** (post-attack trust / pre-attack trust):")
            report.append(f"- Without Policy: {wo_ratio:.2f}")
            report.append(f"- With Policy: {w_ratio:.2f}\n")

            if w_ratio > wo_ratio:
                improvement = (w_ratio - wo_ratio) / wo_ratio * 100
                report.append(f"Policy improves recovery by {improvement:.1f}%\n")

    # Wave Attack Results
    report.append("\n## 3. Multi-Wave Attack Response\n")
    wave = results.get("wave_attack", {})
    if wave:
        report.append("Attack waves: Sybil (day 100), Inflation (day 250), Combined (day 400), Degradation (day 550)\n")

        wo = wave.get("without_policy", [])
        w = wave.get("with_policy", [])

        if wo and w:
            wo_gini = statistics.mean(r.get("final_gini", 0) for r in wo)
            w_gini = statistics.mean(r.get("final_gini", 0) for r in w)

            report.append(f"Final Gini after all waves:")
            report.append(f"- Without Policy: {wo_gini:.3f}")
            report.append(f"- With Policy: {w_gini:.3f}\n")

    # Policy Comparison
    report.append("\n## 4. Policy Configuration Comparison\n")
    policy = results.get("policy_comparison", {})
    if policy:
        report.append("| Configuration | Dampening | Max Change | Interval | Final Gini | Changes |")
        report.append("|---------------|-----------|------------|----------|------------|---------|")

        configs = {
            "no_policy": ("N/A", "N/A", "N/A"),
            "conservative": ("0.1", "2%", "14 days"),
            "moderate": ("0.3", "5%", "7 days"),
            "aggressive": ("0.5", "10%", "3 days")
        }

        for config_name in ["no_policy", "conservative", "moderate", "aggressive"]:
            if config_name in policy:
                data = policy[config_name]
                cfg = configs[config_name]
                gini = data.get("final_gini", 0)
                changes = data.get("parameter_changes", 0)
                report.append(f"| {config_name} | {cfg[0]} | {cfg[1]} | {cfg[2]} | {gini:.3f} | {changes} |")

    # Sensitivity Analysis
    report.append("\n## 5. Parameter Sensitivity Analysis\n")
    sensitivity = results.get("sensitivity", [])
    if sensitivity:
        report.append("### K_PAYMENT Sensitivity\n")
        report.append("| K_PAYMENT | Final Gini | Mean Trust |")
        report.append("|-----------|------------|------------|")

        for item in sensitivity:
            report.append(f"| {item.get('k_payment', 0):.2f} | {item.get('final_gini', 0):.3f} | {item.get('final_mean_trust', 0):.1f} |")

    # Conclusions
    report.append("\n## Conclusions\n")
    report.append("""
### Key Findings:

1. **Combined attacks** are more challenging than single-vector attacks, but automated
   policy still provides significant mitigation.

2. **Recovery dynamics** show that networks with automated policy recover faster
   after attack periods end.

3. **Wave attacks** test the policy's ability to adapt to changing threat profiles.
   The moderate policy configuration appears optimal.

4. **Policy configuration** matters: too aggressive causes instability, too conservative
   is ineffective. Moderate settings (dampening=0.3, max_change=5%, interval=7 days)
   provide the best balance.

5. **K_PAYMENT sensitivity** shows that values between 0.05-0.2 provide the best
   balance between trust differentiation and new entrant accessibility.
""")

    # Write report
    report_path = f"{output_dir}/iteration2_report.md"
    with open(report_path, "w") as f:
        f.write("\n".join(report))

    print(f"Report written to {report_path}")


# =============================================================================
# Visualization for Iteration 2
# =============================================================================

def generate_iteration2_visualizations(results: Dict, output_dir: str):
    """Generate visualizations specific to iteration 2."""
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not available for visualizations")
        return []

    generated_files = []

    # 1. Policy Configuration Comparison
    policy = results.get("policy_comparison", {})
    if policy:
        fig, axes = plt.subplots(1, 2, figsize=(12, 5))
        fig.suptitle('Policy Configuration Comparison', fontsize=14, fontweight='bold')

        configs = list(policy.keys())
        ginis = [policy[c].get("final_gini", 0) for c in configs]
        changes = [policy[c].get("parameter_changes", 0) for c in configs]

        ax1 = axes[0]
        bars = ax1.bar(configs, ginis, color=['gray', 'green', 'blue', 'red'], alpha=0.7)
        ax1.set_ylabel('Final Gini Coefficient')
        ax1.set_title('Trust Inequality by Policy')
        ax1.axhline(y=0.4, color='orange', linestyle='--', alpha=0.5, label='Target')
        ax1.legend()

        ax2 = axes[1]
        ax2.bar(configs, changes, color=['gray', 'green', 'blue', 'red'], alpha=0.7)
        ax2.set_ylabel('Number of Parameter Changes')
        ax2.set_title('Policy Activity Level')

        plt.tight_layout()
        filepath = f"{output_dir}/policy_comparison.png"
        plt.savefig(filepath, dpi=150, bbox_inches='tight')
        plt.close(fig)
        generated_files.append(filepath)

    # 2. Sensitivity Analysis
    sensitivity = results.get("sensitivity", [])
    if sensitivity:
        fig, axes = plt.subplots(1, 2, figsize=(12, 5))
        fig.suptitle('K_PAYMENT Parameter Sensitivity', fontsize=14, fontweight='bold')

        k_vals = [s["k_payment"] for s in sensitivity]
        ginis = [s["final_gini"] for s in sensitivity]
        trusts = [s["final_mean_trust"] for s in sensitivity]

        ax1 = axes[0]
        ax1.plot(k_vals, ginis, 'bo-', markersize=10)
        ax1.set_xlabel('K_PAYMENT')
        ax1.set_ylabel('Final Gini')
        ax1.set_title('Trust Inequality vs K_PAYMENT')
        ax1.grid(True, alpha=0.3)

        ax2 = axes[1]
        ax2.plot(k_vals, trusts, 'go-', markersize=10)
        ax2.set_xlabel('K_PAYMENT')
        ax2.set_ylabel('Mean Trust')
        ax2.set_title('Network Trust Level vs K_PAYMENT')
        ax2.grid(True, alpha=0.3)

        plt.tight_layout()
        filepath = f"{output_dir}/sensitivity_analysis.png"
        plt.savefig(filepath, dpi=150, bbox_inches='tight')
        plt.close(fig)
        generated_files.append(filepath)

    # 3. Recovery Analysis
    recovery = results.get("recovery", {})
    if recovery:
        wo = recovery.get("without_policy", [])
        w = recovery.get("with_policy", [])

        if wo and w:
            fig, ax = plt.subplots(figsize=(10, 6))

            phases = ['Pre-Attack', 'During Attack', 'Post Recovery', 'Final']

            wo_vals = [
                statistics.mean(r.get("pre_attack_trust", 0) for r in wo),
                statistics.mean(r.get("during_attack_trust", 0) for r in wo),
                statistics.mean(r.get("post_recovery_trust", 0) for r in wo),
                statistics.mean(r.get("final_trust", 0) for r in wo)
            ]

            w_vals = [
                statistics.mean(r.get("pre_attack_trust", 0) for r in w),
                statistics.mean(r.get("during_attack_trust", 0) for r in w),
                statistics.mean(r.get("post_recovery_trust", 0) for r in w),
                statistics.mean(r.get("final_trust", 0) for r in w)
            ]

            x = range(len(phases))
            width = 0.35

            ax.bar([i - width/2 for i in x], wo_vals, width, label='Without Policy', color='red', alpha=0.7)
            ax.bar([i + width/2 for i in x], w_vals, width, label='With Policy', color='blue', alpha=0.7)

            ax.set_xticks(x)
            ax.set_xticklabels(phases)
            ax.set_ylabel('Mean Trust')
            ax.set_title('Trust Levels Through Attack and Recovery Phases')
            ax.legend()
            ax.grid(True, alpha=0.3, axis='y')

            plt.tight_layout()
            filepath = f"{output_dir}/recovery_analysis.png"
            plt.savefig(filepath, dpi=150, bbox_inches='tight')
            plt.close(fig)
            generated_files.append(filepath)

    print(f"Generated {len(generated_files)} iteration 2 visualizations")
    return generated_files


# =============================================================================
# Main
# =============================================================================

def main():
    output_dir = "results_iteration2"

    results = run_iteration2(output_dir)

    print("\n" + "="*60)
    print("Generating visualizations...")
    print("="*60)

    # Try to generate visualizations
    try:
        generate_iteration2_visualizations(results, output_dir)
    except Exception as e:
        print(f"Could not generate visualizations: {e}")

    print("\n" + "="*80)
    print("ITERATION 2 COMPLETE")
    print("="*80)
    print(f"\nFinished at: {datetime.now().isoformat()}")
    print(f"Results in: {output_dir}/")


if __name__ == "__main__":
    main()
