#!/usr/bin/env python3
"""
Generate visualizations from monetary policy simulation results.

Creates graphs showing:
- Trust distribution over time
- Gini coefficient evolution
- Parameter adjustments over time
- Attack impact comparisons
- Metric correlations
"""

import json
import os
from typing import Dict, List, Any, Optional
from dataclasses import dataclass

# Check for matplotlib availability
try:
    import matplotlib
    matplotlib.use('Agg')  # Non-interactive backend for server
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    from matplotlib.gridspec import GridSpec
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("Warning: matplotlib not available. Install with: pip install matplotlib")

# Try numpy for statistics
try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False
    import statistics
    print("Warning: numpy not available, using statistics module")


def load_results(results_dir: str = "results") -> Dict[str, Any]:
    """Load all result files."""
    results = {}

    # Load main experiments
    all_exp_path = os.path.join(results_dir, "all_experiments.json")
    if os.path.exists(all_exp_path):
        with open(all_exp_path) as f:
            results["experiments"] = json.load(f)

    # Load extended baseline
    baseline_path = os.path.join(results_dir, "extended_baseline_metrics.json")
    if os.path.exists(baseline_path):
        with open(baseline_path) as f:
            results["extended_baseline"] = json.load(f)

    # Load adversarial simulation
    adversarial_path = os.path.join(results_dir, "adversarial_multi_attack_metrics.json")
    if os.path.exists(adversarial_path):
        with open(adversarial_path) as f:
            results["adversarial"] = json.load(f)

    return results


def plot_trust_evolution(results: Dict, output_dir: str):
    """Plot trust metrics over time for each experiment."""
    if not HAS_MATPLOTLIB:
        return []

    generated_files = []
    experiments = results.get("experiments", {}).get("experiments", [])

    for exp in experiments:
        name = exp.get("name", "Unknown")
        safe_name = name.replace(" ", "_").replace("/", "_").replace("(", "").replace(")", "")

        fig, axes = plt.subplots(2, 2, figsize=(14, 10))
        fig.suptitle(f'{name}: Trust Evolution Over Time', fontsize=14, fontweight='bold')

        # Get metrics from with and without policy
        with_policy = exp.get("with_policy", [])
        without_policy = exp.get("without_policy", [])

        if not with_policy or not without_policy:
            plt.close(fig)
            continue

        # Use first run for visualization
        wp_metrics = with_policy[0].get("metrics_history", [])
        wop_metrics = without_policy[0].get("metrics_history", [])

        if not wp_metrics or not wop_metrics:
            plt.close(fig)
            continue

        # Extract data
        wp_days = [m["day"] for m in wp_metrics]
        wop_days = [m["day"] for m in wop_metrics]

        # Plot 1: Mean Trust
        ax1 = axes[0, 0]
        wp_trust = [m["mean_trust"] for m in wp_metrics]
        wop_trust = [m["mean_trust"] for m in wop_metrics]
        ax1.plot(wop_days, wop_trust, 'r-', label='Without Policy', alpha=0.7)
        ax1.plot(wp_days, wp_trust, 'b-', label='With Policy', alpha=0.7)
        ax1.set_xlabel('Day')
        ax1.set_ylabel('Mean Trust')
        ax1.set_title('Mean Trust Over Time')
        ax1.legend()
        ax1.grid(True, alpha=0.3)

        # Plot 2: Gini Coefficient
        ax2 = axes[0, 1]
        wp_gini = [m["trust_gini"] for m in wp_metrics]
        wop_gini = [m["trust_gini"] for m in wop_metrics]
        ax2.plot(wop_days, wop_gini, 'r-', label='Without Policy', alpha=0.7)
        ax2.plot(wp_days, wp_gini, 'b-', label='With Policy', alpha=0.7)
        ax2.axhline(y=0.4, color='g', linestyle='--', alpha=0.5, label='Target Gini')
        ax2.set_xlabel('Day')
        ax2.set_ylabel('Gini Coefficient')
        ax2.set_title('Trust Inequality (Gini) Over Time')
        ax2.legend()
        ax2.grid(True, alpha=0.3)

        # Plot 3: Cluster Prevalence
        ax3 = axes[1, 0]
        wp_cluster = [m["cluster_prevalence"] for m in wp_metrics]
        wop_cluster = [m["cluster_prevalence"] for m in wop_metrics]
        ax3.plot(wop_days, wop_cluster, 'r-', label='Without Policy', alpha=0.7)
        ax3.plot(wp_days, wp_cluster, 'b-', label='With Policy', alpha=0.7)
        ax3.set_xlabel('Day')
        ax3.set_ylabel('Cluster Prevalence')
        ax3.set_title('Sybil Cluster Detection Over Time')
        ax3.legend()
        ax3.grid(True, alpha=0.3)

        # Plot 4: Daily Transactions
        ax4 = axes[1, 1]
        wp_txs = [m["daily_transactions"] for m in wp_metrics]
        wop_txs = [m["daily_transactions"] for m in wop_metrics]
        ax4.plot(wop_days, wop_txs, 'r-', label='Without Policy', alpha=0.7)
        ax4.plot(wp_days, wp_txs, 'b-', label='With Policy', alpha=0.7)
        ax4.set_xlabel('Day')
        ax4.set_ylabel('Daily Transactions')
        ax4.set_title('Transaction Volume Over Time')
        ax4.legend()
        ax4.grid(True, alpha=0.3)

        plt.tight_layout()

        filepath = os.path.join(output_dir, f"trust_evolution_{safe_name}.png")
        plt.savefig(filepath, dpi=150, bbox_inches='tight')
        plt.close(fig)
        generated_files.append(filepath)
        print(f"  Generated: {filepath}")

    return generated_files


def plot_parameter_adjustments(results: Dict, output_dir: str):
    """Plot parameter changes made by automated policy."""
    if not HAS_MATPLOTLIB:
        return []

    generated_files = []
    experiments = results.get("experiments", {}).get("experiments", [])

    # Collect all parameter changes across experiments
    all_changes = {}

    for exp in experiments:
        name = exp.get("name", "Unknown")
        with_policy = exp.get("with_policy", [])

        if not with_policy:
            continue

        # Get parameter changes from first run
        changes = with_policy[0].get("parameter_changes", [])

        for change_event in changes:
            day = change_event.get("day", 0)
            for c in change_event.get("changes", []):
                param = c.get("parameter", "unknown")
                if param not in all_changes:
                    all_changes[param] = {"days": [], "values": [], "experiments": []}
                all_changes[param]["days"].append(day)
                all_changes[param]["values"].append(c.get("new_value", 0))
                all_changes[param]["experiments"].append(name)

    if not all_changes:
        return generated_files

    # Create parameter adjustment timeline
    fig, axes = plt.subplots(len(all_changes), 1, figsize=(12, 3 * len(all_changes)))
    fig.suptitle('Automated Parameter Adjustments Over Time', fontsize=14, fontweight='bold')

    if len(all_changes) == 1:
        axes = [axes]

    colors = plt.cm.tab10.colors

    for idx, (param, data) in enumerate(all_changes.items()):
        ax = axes[idx]

        # Group by experiment
        exp_data = {}
        for d, v, e in zip(data["days"], data["values"], data["experiments"]):
            if e not in exp_data:
                exp_data[e] = {"days": [], "values": []}
            exp_data[e]["days"].append(d)
            exp_data[e]["values"].append(v)

        for i, (exp_name, exp_vals) in enumerate(exp_data.items()):
            color = colors[i % len(colors)]
            ax.scatter(exp_vals["days"], exp_vals["values"],
                      label=exp_name[:20], color=color, alpha=0.7, s=50)
            # Connect points for same experiment
            sorted_idx = sorted(range(len(exp_vals["days"])), key=lambda k: exp_vals["days"][k])
            sorted_days = [exp_vals["days"][i] for i in sorted_idx]
            sorted_vals = [exp_vals["values"][i] for i in sorted_idx]
            ax.plot(sorted_days, sorted_vals, color=color, alpha=0.3)

        ax.set_xlabel('Day')
        ax.set_ylabel(param)
        ax.set_title(f'Parameter: {param}')
        ax.legend(loc='upper right', fontsize=8)
        ax.grid(True, alpha=0.3)

    plt.tight_layout()

    filepath = os.path.join(output_dir, "parameter_adjustments.png")
    plt.savefig(filepath, dpi=150, bbox_inches='tight')
    plt.close(fig)
    generated_files.append(filepath)
    print(f"  Generated: {filepath}")

    return generated_files


def plot_attack_comparison(results: Dict, output_dir: str):
    """Create comparison bar charts for all attacks."""
    if not HAS_MATPLOTLIB:
        return []

    generated_files = []
    experiments = results.get("experiments", {}).get("experiments", [])

    if not experiments:
        return generated_files

    # Collect final metrics for comparison
    exp_names = []
    wp_gini = []
    wop_gini = []
    wp_cluster = []
    wop_cluster = []
    wp_trust = []
    wop_trust = []

    for exp in experiments:
        name = exp.get("name", "Unknown")
        with_policy = exp.get("with_policy", [])
        without_policy = exp.get("without_policy", [])

        if not with_policy or not without_policy:
            continue

        exp_names.append(name[:25])

        # Average across runs
        if HAS_NUMPY:
            wp_gini.append(np.mean([r.get("final_gini", 0) for r in with_policy]))
            wop_gini.append(np.mean([r.get("final_gini", 0) for r in without_policy]))
            wp_cluster.append(np.mean([r.get("final_cluster_prevalence", 0) for r in with_policy]))
            wop_cluster.append(np.mean([r.get("final_cluster_prevalence", 0) for r in without_policy]))
            wp_trust.append(np.mean([r.get("final_mean_trust", 0) for r in with_policy]))
            wop_trust.append(np.mean([r.get("final_mean_trust", 0) for r in without_policy]))
        else:
            wp_gini.append(statistics.mean([r.get("final_gini", 0) for r in with_policy]))
            wop_gini.append(statistics.mean([r.get("final_gini", 0) for r in without_policy]))
            wp_cluster.append(statistics.mean([r.get("final_cluster_prevalence", 0) for r in with_policy]))
            wop_cluster.append(statistics.mean([r.get("final_cluster_prevalence", 0) for r in without_policy]))
            wp_trust.append(statistics.mean([r.get("final_mean_trust", 0) for r in with_policy]))
            wop_trust.append(statistics.mean([r.get("final_mean_trust", 0) for r in without_policy]))

    if not exp_names:
        return generated_files

    # Create comparison figure
    fig, axes = plt.subplots(1, 3, figsize=(16, 6))
    fig.suptitle('Attack Scenario Comparison: With vs Without Automated Policy',
                 fontsize=14, fontweight='bold')

    x = range(len(exp_names))
    width = 0.35

    # Gini comparison
    ax1 = axes[0]
    bars1 = ax1.bar([i - width/2 for i in x], wop_gini, width, label='Without Policy', color='red', alpha=0.7)
    bars2 = ax1.bar([i + width/2 for i in x], wp_gini, width, label='With Policy', color='blue', alpha=0.7)
    ax1.axhline(y=0.4, color='green', linestyle='--', alpha=0.5, label='Target')
    ax1.set_ylabel('Gini Coefficient')
    ax1.set_title('Trust Inequality')
    ax1.set_xticks(x)
    ax1.set_xticklabels(exp_names, rotation=45, ha='right', fontsize=8)
    ax1.legend()
    ax1.grid(True, alpha=0.3, axis='y')

    # Cluster prevalence comparison
    ax2 = axes[1]
    ax2.bar([i - width/2 for i in x], wop_cluster, width, label='Without Policy', color='red', alpha=0.7)
    ax2.bar([i + width/2 for i in x], wp_cluster, width, label='With Policy', color='blue', alpha=0.7)
    ax2.set_ylabel('Cluster Prevalence')
    ax2.set_title('Sybil Cluster Detection')
    ax2.set_xticks(x)
    ax2.set_xticklabels(exp_names, rotation=45, ha='right', fontsize=8)
    ax2.legend()
    ax2.grid(True, alpha=0.3, axis='y')

    # Mean trust comparison
    ax3 = axes[2]
    ax3.bar([i - width/2 for i in x], wop_trust, width, label='Without Policy', color='red', alpha=0.7)
    ax3.bar([i + width/2 for i in x], wp_trust, width, label='With Policy', color='blue', alpha=0.7)
    ax3.set_ylabel('Mean Trust')
    ax3.set_title('Network Trust Level')
    ax3.set_xticks(x)
    ax3.set_xticklabels(exp_names, rotation=45, ha='right', fontsize=8)
    ax3.legend()
    ax3.grid(True, alpha=0.3, axis='y')

    plt.tight_layout()

    filepath = os.path.join(output_dir, "attack_comparison.png")
    plt.savefig(filepath, dpi=150, bbox_inches='tight')
    plt.close(fig)
    generated_files.append(filepath)
    print(f"  Generated: {filepath}")

    return generated_files


def plot_extended_simulation(results: Dict, output_dir: str):
    """Plot metrics from extended 5-year simulations."""
    if not HAS_MATPLOTLIB:
        return []

    generated_files = []

    # Extended baseline
    if "extended_baseline" in results:
        baseline = results["extended_baseline"]
        metrics = baseline.get("metrics", [])

        if metrics:
            fig, axes = plt.subplots(2, 2, figsize=(14, 10))
            fig.suptitle('Extended 5-Year Baseline Simulation', fontsize=14, fontweight='bold')

            days = [m["day"] for m in metrics]

            # Mean Trust
            ax1 = axes[0, 0]
            ax1.plot(days, [m["mean_trust"] for m in metrics], 'b-', alpha=0.7)
            ax1.set_xlabel('Day')
            ax1.set_ylabel('Mean Trust')
            ax1.set_title('Mean Trust Over 5 Years')
            ax1.grid(True, alpha=0.3)

            # Gini
            ax2 = axes[0, 1]
            ax2.plot(days, [m["trust_gini"] for m in metrics], 'g-', alpha=0.7)
            ax2.axhline(y=0.4, color='r', linestyle='--', alpha=0.5, label='Target')
            ax2.set_xlabel('Day')
            ax2.set_ylabel('Gini Coefficient')
            ax2.set_title('Trust Inequality Over 5 Years')
            ax2.legend()
            ax2.grid(True, alpha=0.3)

            # Total Identities
            ax3 = axes[1, 0]
            ax3.plot(days, [m["total_identities"] for m in metrics], 'purple', alpha=0.7)
            ax3.set_xlabel('Day')
            ax3.set_ylabel('Total Identities')
            ax3.set_title('Network Growth')
            ax3.grid(True, alpha=0.3)

            # Daily Transactions
            ax4 = axes[1, 1]
            ax4.plot(days, [m["daily_transactions"] for m in metrics], 'orange', alpha=0.7)
            ax4.set_xlabel('Day')
            ax4.set_ylabel('Daily Transactions')
            ax4.set_title('Transaction Volume')
            ax4.grid(True, alpha=0.3)

            plt.tight_layout()

            filepath = os.path.join(output_dir, "extended_baseline_5year.png")
            plt.savefig(filepath, dpi=150, bbox_inches='tight')
            plt.close(fig)
            generated_files.append(filepath)
            print(f"  Generated: {filepath}")

    # Adversarial multi-attack
    if "adversarial" in results:
        adversarial = results["adversarial"]
        metrics = adversarial.get("metrics", [])

        if metrics:
            fig, axes = plt.subplots(2, 2, figsize=(14, 10))
            fig.suptitle('5-Year Adversarial Multi-Attack Simulation', fontsize=14, fontweight='bold')

            days = [m["day"] for m in metrics]

            # Attack wave markers
            attack_days = {180: "Sybil", 450: "Inflation", 720: "Hoarding",
                          990: "Degradation", 1260: "Coordinated"}

            # Mean Trust with attack markers
            ax1 = axes[0, 0]
            ax1.plot(days, [m["mean_trust"] for m in metrics], 'b-', alpha=0.7)
            for attack_day, attack_name in attack_days.items():
                ax1.axvline(x=attack_day, color='r', linestyle='--', alpha=0.3)
                ax1.text(attack_day, ax1.get_ylim()[1] * 0.9, attack_name,
                        rotation=90, fontsize=8, alpha=0.7)
            ax1.set_xlabel('Day')
            ax1.set_ylabel('Mean Trust')
            ax1.set_title('Mean Trust Under Attack')
            ax1.grid(True, alpha=0.3)

            # Cluster Prevalence
            ax2 = axes[0, 1]
            ax2.plot(days, [m["cluster_prevalence"] for m in metrics], 'r-', alpha=0.7)
            for attack_day in attack_days.keys():
                ax2.axvline(x=attack_day, color='gray', linestyle='--', alpha=0.3)
            ax2.set_xlabel('Day')
            ax2.set_ylabel('Cluster Prevalence')
            ax2.set_title('Sybil Detection Under Attack')
            ax2.grid(True, alpha=0.3)

            # Gini
            ax3 = axes[1, 0]
            ax3.plot(days, [m["trust_gini"] for m in metrics], 'g-', alpha=0.7)
            ax3.axhline(y=0.4, color='orange', linestyle='--', alpha=0.5, label='Target')
            for attack_day in attack_days.keys():
                ax3.axvline(x=attack_day, color='gray', linestyle='--', alpha=0.3)
            ax3.set_xlabel('Day')
            ax3.set_ylabel('Gini Coefficient')
            ax3.set_title('Trust Inequality Under Attack')
            ax3.legend()
            ax3.grid(True, alpha=0.3)

            # Total Identities
            ax4 = axes[1, 1]
            ax4.plot(days, [m["total_identities"] for m in metrics], 'purple', alpha=0.7)
            for attack_day, attack_name in attack_days.items():
                ax4.axvline(x=attack_day, color='gray', linestyle='--', alpha=0.3)
            ax4.set_xlabel('Day')
            ax4.set_ylabel('Total Identities')
            ax4.set_title('Network Size (including attackers)')
            ax4.grid(True, alpha=0.3)

            plt.tight_layout()

            filepath = os.path.join(output_dir, "adversarial_multi_attack_5year.png")
            plt.savefig(filepath, dpi=150, bbox_inches='tight')
            plt.close(fig)
            generated_files.append(filepath)
            print(f"  Generated: {filepath}")

    return generated_files


def plot_policy_effectiveness_heatmap(results: Dict, output_dir: str):
    """Create heatmap showing policy effectiveness across metrics and attacks."""
    if not HAS_MATPLOTLIB:
        return []

    generated_files = []
    experiments = results.get("experiments", {}).get("experiments", [])

    if not experiments:
        return generated_files

    # Calculate improvement percentages
    metrics = ["Gini", "Cluster Prev.", "Failure Rate", "Hoarding"]
    exp_names = []
    improvements = []

    for exp in experiments:
        name = exp.get("name", "Unknown")
        with_policy = exp.get("with_policy", [])
        without_policy = exp.get("without_policy", [])

        if not with_policy or not without_policy:
            continue

        exp_names.append(name[:20])

        row = []

        # Gini improvement (lower is better)
        wp_gini = sum(r.get("final_gini", 0) for r in with_policy) / len(with_policy)
        wop_gini = sum(r.get("final_gini", 0) for r in without_policy) / len(without_policy)
        gini_imp = ((wop_gini - wp_gini) / wop_gini * 100) if wop_gini > 0 else 0
        row.append(gini_imp)

        # Cluster improvement (lower is better)
        wp_cl = sum(r.get("final_cluster_prevalence", 0) for r in with_policy) / len(with_policy)
        wop_cl = sum(r.get("final_cluster_prevalence", 0) for r in without_policy) / len(without_policy)
        cl_imp = ((wop_cl - wp_cl) / wop_cl * 100) if wop_cl > 0 else 0
        row.append(cl_imp)

        # Failure rate improvement (lower is better)
        wp_fr = sum(r.get("verification_failure_rate", 0) for r in with_policy) / len(with_policy)
        wop_fr = sum(r.get("verification_failure_rate", 0) for r in without_policy) / len(without_policy)
        fr_imp = ((wop_fr - wp_fr) / wop_fr * 100) if wop_fr > 0 else 0
        row.append(fr_imp)

        # Hoarding improvement (lower is better)
        wp_h = sum(r.get("hoarding_prevalence", 0) for r in with_policy) / len(with_policy)
        wop_h = sum(r.get("hoarding_prevalence", 0) for r in without_policy) / len(without_policy)
        h_imp = ((wop_h - wp_h) / wop_h * 100) if wop_h > 0 else 0
        row.append(h_imp)

        improvements.append(row)

    if not improvements:
        return generated_files

    # Create heatmap
    fig, ax = plt.subplots(figsize=(10, 8))

    if HAS_NUMPY:
        data = np.array(improvements)
    else:
        data = improvements

    # Create heatmap manually without numpy
    im = ax.imshow([[0]], cmap='RdYlGn', vmin=-50, vmax=50)

    # Clear and redraw properly
    ax.clear()

    # Draw cells
    for i, row in enumerate(improvements):
        for j, val in enumerate(row):
            color = plt.cm.RdYlGn((val + 50) / 100)  # Normalize to 0-1
            rect = plt.Rectangle((j - 0.5, i - 0.5), 1, 1, color=color)
            ax.add_patch(rect)
            text_color = 'white' if abs(val) > 25 else 'black'
            ax.text(j, i, f'{val:.1f}%', ha='center', va='center', color=text_color, fontsize=10)

    ax.set_xlim(-0.5, len(metrics) - 0.5)
    ax.set_ylim(-0.5, len(exp_names) - 0.5)
    ax.set_xticks(range(len(metrics)))
    ax.set_xticklabels(metrics)
    ax.set_yticks(range(len(exp_names)))
    ax.set_yticklabels(exp_names)
    ax.invert_yaxis()

    ax.set_title('Policy Effectiveness: % Improvement Over No Policy\n(Green = Better, Red = Worse)',
                 fontsize=12, fontweight='bold')

    # Colorbar
    sm = plt.cm.ScalarMappable(cmap='RdYlGn', norm=plt.Normalize(vmin=-50, vmax=50))
    sm.set_array([])
    cbar = plt.colorbar(sm, ax=ax)
    cbar.set_label('% Improvement')

    plt.tight_layout()

    filepath = os.path.join(output_dir, "policy_effectiveness_heatmap.png")
    plt.savefig(filepath, dpi=150, bbox_inches='tight')
    plt.close(fig)
    generated_files.append(filepath)
    print(f"  Generated: {filepath}")

    return generated_files


def plot_parameter_sensitivity(results: Dict, output_dir: str):
    """Show how different parameter values correlate with outcomes."""
    if not HAS_MATPLOTLIB:
        return []

    generated_files = []
    experiments = results.get("experiments", {}).get("experiments", [])

    # Collect parameter values and outcomes
    k_payment_values = []
    final_gini_values = []

    for exp in experiments:
        with_policy = exp.get("with_policy", [])
        for run in with_policy:
            params = run.get("final_params", {})
            if "k_payment" in params:
                k_payment_values.append(params["k_payment"])
                final_gini_values.append(run.get("final_gini", 0))

    if len(k_payment_values) > 3:
        fig, ax = plt.subplots(figsize=(10, 6))
        ax.scatter(k_payment_values, final_gini_values, alpha=0.6, s=100)
        ax.set_xlabel('K_PAYMENT Parameter Value')
        ax.set_ylabel('Final Gini Coefficient')
        ax.set_title('Parameter Sensitivity: K_PAYMENT vs Trust Inequality')
        ax.grid(True, alpha=0.3)

        # Add trend line if numpy available
        if HAS_NUMPY and len(k_payment_values) > 2:
            z = np.polyfit(k_payment_values, final_gini_values, 1)
            p = np.poly1d(z)
            x_line = np.linspace(min(k_payment_values), max(k_payment_values), 100)
            ax.plot(x_line, p(x_line), 'r--', alpha=0.5, label='Trend')
            ax.legend()

        plt.tight_layout()

        filepath = os.path.join(output_dir, "parameter_sensitivity.png")
        plt.savefig(filepath, dpi=150, bbox_inches='tight')
        plt.close(fig)
        generated_files.append(filepath)
        print(f"  Generated: {filepath}")

    return generated_files


def update_report_with_figures(report_path: str, figures: List[str]):
    """Update the markdown report to include generated figures."""
    if not os.path.exists(report_path):
        print(f"Report not found: {report_path}")
        return

    with open(report_path) as f:
        content = f.read()

    # Add figures section
    figures_section = "\n\n## Visualizations\n\n"
    figures_section += "The following graphs were automatically generated from the simulation data:\n\n"

    for fig_path in figures:
        fig_name = os.path.basename(fig_path)
        # Use relative path for markdown
        rel_path = fig_name

        # Generate description based on filename
        if "trust_evolution" in fig_name:
            desc = "Trust metrics evolution over time comparing with/without automated policy"
        elif "parameter_adjustments" in fig_name:
            desc = "Timeline of automated parameter adjustments"
        elif "attack_comparison" in fig_name:
            desc = "Side-by-side comparison of all attack scenarios"
        elif "extended_baseline" in fig_name:
            desc = "5-year extended baseline simulation metrics"
        elif "adversarial" in fig_name:
            desc = "5-year adversarial multi-attack simulation with attack wave markers"
        elif "heatmap" in fig_name:
            desc = "Heatmap showing policy effectiveness across metrics and scenarios"
        elif "sensitivity" in fig_name:
            desc = "Parameter sensitivity analysis"
        else:
            desc = "Simulation visualization"

        figures_section += f"### {fig_name.replace('.png', '').replace('_', ' ').title()}\n\n"
        figures_section += f"![{desc}]({rel_path})\n\n"
        figures_section += f"*{desc}*\n\n"

    # Insert before Conclusions section
    if "## Conclusions" in content:
        content = content.replace("## Conclusions", figures_section + "## Conclusions")
    else:
        content += figures_section

    with open(report_path, "w") as f:
        f.write(content)

    print(f"Updated report with {len(figures)} figures")


def main():
    """Generate all visualizations."""
    print("="*60)
    print("GENERATING VISUALIZATIONS")
    print("="*60)

    if not HAS_MATPLOTLIB:
        print("\nERROR: matplotlib is required for visualizations.")
        print("Install with: pip install matplotlib")
        return

    results_dir = "results"
    output_dir = results_dir  # Put figures in same directory as report

    print(f"\nLoading results from {results_dir}/...")
    results = load_results(results_dir)

    if not results:
        print("No results found. Run the simulation first.")
        return

    all_figures = []

    print("\nGenerating trust evolution plots...")
    all_figures.extend(plot_trust_evolution(results, output_dir))

    print("\nGenerating parameter adjustment timeline...")
    all_figures.extend(plot_parameter_adjustments(results, output_dir))

    print("\nGenerating attack comparison chart...")
    all_figures.extend(plot_attack_comparison(results, output_dir))

    print("\nGenerating extended simulation plots...")
    all_figures.extend(plot_extended_simulation(results, output_dir))

    print("\nGenerating policy effectiveness heatmap...")
    all_figures.extend(plot_policy_effectiveness_heatmap(results, output_dir))

    print("\nGenerating parameter sensitivity analysis...")
    all_figures.extend(plot_parameter_sensitivity(results, output_dir))

    # Update report with figures
    report_path = os.path.join(results_dir, "simulation_report.md")
    if all_figures:
        print(f"\nUpdating report at {report_path}...")
        update_report_with_figures(report_path, all_figures)

    print("\n" + "="*60)
    print(f"VISUALIZATION COMPLETE: Generated {len(all_figures)} figures")
    print("="*60)


if __name__ == "__main__":
    main()
