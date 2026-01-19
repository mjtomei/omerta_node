"""
Mock implementations for VM connectivity checks.

In production, these would SSH to the VM or check wireguard status.
For simulation, they return configurable values.
"""

# Simulation configuration - can be modified by tests
_simulation_config = {
    "vm_reachable": True,
    "consumer_connected": True,
}


def configure(vm_reachable: bool = True, consumer_connected: bool = True):
    """Configure simulation behavior."""
    _simulation_config["vm_reachable"] = vm_reachable
    _simulation_config["consumer_connected"] = consumer_connected


def reset():
    """Reset to default configuration."""
    _simulation_config["vm_reachable"] = True
    _simulation_config["consumer_connected"] = True


def check_vm_connectivity(vm_endpoint: str) -> bool:
    """
    Check if the VM is reachable.

    In production: SSH to vm_endpoint and verify connectivity.
    In simulation: Returns configured value (default True).

    Args:
        vm_endpoint: The VM's wireguard endpoint (e.g., "10.0.0.1:51820")

    Returns:
        True if VM is reachable, False otherwise.
    """
    return _simulation_config["vm_reachable"]


def check_consumer_connected(session_id: str) -> bool:
    """
    Check if the consumer is connected to the VM.

    In production: Query wireguard status or check session state.
    In simulation: Returns configured value (default True).

    Args:
        session_id: The session identifier

    Returns:
        True if consumer appears connected, False otherwise.
    """
    return _simulation_config["consumer_connected"]
