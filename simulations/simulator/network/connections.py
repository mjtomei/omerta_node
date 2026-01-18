"""
Connection type definitions with bandwidth and latency characteristics.
"""

from dataclasses import dataclass
from typing import Dict


@dataclass
class ConnectionType:
    """Network connection characteristics for a node."""
    name: str
    upload_mbps: float
    download_mbps: float
    added_latency_ms: float
    packet_loss_rate: float


CONNECTION_TYPES: Dict[str, ConnectionType] = {
    # Datacenter / cloud
    "datacenter": ConnectionType(
        name="Datacenter",
        upload_mbps=10000,      # 10 Gbps
        download_mbps=10000,
        added_latency_ms=1,
        packet_loss_rate=0.0001,
    ),

    # Residential fiber
    "fiber": ConnectionType(
        name="Residential Fiber",
        upload_mbps=1000,       # 1 Gbps symmetric
        download_mbps=1000,
        added_latency_ms=2,
        packet_loss_rate=0.0005,
    ),

    # Cable internet (asymmetric)
    "cable": ConnectionType(
        name="Cable Internet",
        upload_mbps=20,         # Typical cable upload
        download_mbps=200,      # Typical cable download
        added_latency_ms=10,
        packet_loss_rate=0.001,
    ),

    # DSL (asymmetric, slower)
    "dsl": ConnectionType(
        name="DSL",
        upload_mbps=5,
        download_mbps=50,
        added_latency_ms=15,
        packet_loss_rate=0.005,
    ),

    # Mobile 4G LTE
    "4g_lte": ConnectionType(
        name="4G LTE",
        upload_mbps=10,
        download_mbps=50,
        added_latency_ms=40,
        packet_loss_rate=0.02,
    ),

    # Mobile 5G
    "5g": ConnectionType(
        name="5G",
        upload_mbps=100,
        download_mbps=500,
        added_latency_ms=10,
        packet_loss_rate=0.005,
    ),

    # Satellite (LEO - Starlink style)
    "satellite_leo": ConnectionType(
        name="LEO Satellite",
        upload_mbps=20,
        download_mbps=100,
        added_latency_ms=25,
        packet_loss_rate=0.01,
    ),

    # Satellite (GEO - traditional)
    "satellite_geo": ConnectionType(
        name="GEO Satellite",
        upload_mbps=5,
        download_mbps=25,
        added_latency_ms=600,   # ~36000km orbital latency
        packet_loss_rate=0.02,
    ),
}
