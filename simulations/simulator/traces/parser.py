"""
YAML trace parser.
"""

import os
from typing import Any, Dict, List

import yaml

from .schema import (
    Trace, TraceAction, TraceAssertion,
    TraceNetworkSpec, TraceNodeSpec, TracePartitionSpec,
    TraceSetup, TraceChainSpec, TraceRelationship,
    ValidationError,
)
from ..network.regions import Region
from ..network.connections import CONNECTION_TYPES


def parse_trace(yaml_content: str) -> Trace:
    """Parse a trace from YAML content."""
    data = yaml.safe_load(yaml_content)
    return _parse_trace_dict(data)


def load_trace(file_path: str) -> Trace:
    """Load a trace from a YAML file."""
    with open(file_path, 'r') as f:
        return parse_trace(f.read())


def _parse_trace_dict(data: Dict[str, Any]) -> Trace:
    """Parse a trace from a dictionary."""
    # Validate required fields
    required = ["name", "description", "network", "setup", "actions", "assertions"]
    for field in required:
        if field not in data:
            raise ValidationError(f"Missing required field: {field}")

    # Parse network
    network = _parse_network(data["network"])

    # Parse setup
    setup = _parse_setup(data["setup"])

    # Parse actions
    actions = _parse_actions(data["actions"])

    # Parse assertions
    assertions = _parse_assertions(data["assertions"])

    return Trace(
        name=data["name"],
        description=data["description"],
        network=network,
        setup=setup,
        actions=actions,
        assertions=assertions,
    )


def _parse_network(data: Dict[str, Any]) -> TraceNetworkSpec:
    """Parse network specification."""
    seed = data.get("seed", 42)

    # Parse nodes
    nodes = []
    for node_data in data.get("nodes", []):
        node = _parse_node(node_data)
        nodes.append(node)

    # Parse partitions
    partitions = []
    for part_data in data.get("partitions", []):
        partition = _parse_partition(part_data)
        partitions.append(partition)

    return TraceNetworkSpec(seed=seed, nodes=nodes, partitions=partitions)


def _parse_node(data: Dict[str, Any]) -> TraceNodeSpec:
    """Parse a node specification."""
    node_id = data["id"]
    region_str = data["region"]
    connection = data["connection"]

    # Validate region
    region = _parse_region(region_str)

    # Validate connection type
    if connection not in CONNECTION_TYPES:
        raise ValidationError(f"Invalid connection type: {connection}. Valid types: {list(CONNECTION_TYPES.keys())}")

    return TraceNodeSpec(id=node_id, region=region, connection=connection)


def _parse_region(region_str: str) -> Region:
    """Parse a region string to Region enum."""
    region_map = {
        "north_america": Region.NORTH_AMERICA,
        "europe": Region.EUROPE,
        "asia": Region.ASIA,
        "japan": Region.JAPAN,
        "australia": Region.AUSTRALIA,
        "south_america": Region.SOUTH_AMERICA,
    }

    region_lower = region_str.lower()
    if region_lower not in region_map:
        raise ValidationError(f"Invalid region: {region_str}. Valid regions: {list(region_map.keys())}")

    return region_map[region_lower]


def _parse_partition(data: Dict[str, Any]) -> TracePartitionSpec:
    """Parse a partition specification."""
    groups = [set(g) for g in data["groups"]]
    start_time = float(data["start_time"])
    duration = float(data["duration"])

    return TracePartitionSpec(groups=groups, start_time=start_time, duration=duration)


def _parse_setup(data: Dict[str, Any]) -> TraceSetup:
    """Parse setup specification."""
    # Parse chains
    chains = {}
    for actor_id, chain_data in data.get("chains", {}).items():
        if isinstance(chain_data, dict):
            chains[actor_id] = TraceChainSpec(
                balance=chain_data.get("balance", 0.0),
                trust=chain_data.get("trust", 1.0),
            )
        else:
            chains[actor_id] = TraceChainSpec()

    # Parse relationships
    relationships = []
    for rel_data in data.get("relationships", []):
        relationships.append(TraceRelationship(
            peers=rel_data["peers"],
            age_days=rel_data.get("age_days", 0),
        ))

    return TraceSetup(chains=chains, relationships=relationships)


def _parse_actions(data: List[Dict[str, Any]]) -> List[TraceAction]:
    """Parse action list."""
    actions = []
    for action_data in data:
        action = TraceAction(
            time=float(action_data["time"]),
            actor=action_data["actor"],
            action=action_data["action"],
            params=action_data.get("params", {}),
            expected_result=action_data.get("expected_result"),
        )
        actions.append(action)

    # Sort by time
    actions.sort(key=lambda a: a.time)

    return actions


def _parse_assertions(data: List[Dict[str, Any]]) -> List[TraceAssertion]:
    """Parse assertion list."""
    assertions = []
    for assert_data in data:
        assertion = TraceAssertion(
            type=assert_data["type"],
            description=assert_data.get("description", ""),
            params={k: v for k, v in assert_data.items() if k not in ["type", "description"]},
        )
        assertions.append(assertion)

    return assertions
