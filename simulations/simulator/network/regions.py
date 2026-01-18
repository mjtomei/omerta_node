"""
Geographic regions and inter-region latency data.

Based on SimBlock paper measurements from Bitcoin network circa 2019.
"""

from enum import Enum
from typing import Dict, Tuple


class Region(Enum):
    """Geographic regions with measured network parameters."""
    NORTH_AMERICA = "north_america"
    EUROPE = "europe"
    ASIA = "asia"
    JAPAN = "japan"
    AUSTRALIA = "australia"
    SOUTH_AMERICA = "south_america"


# Inter-region propagation delays in milliseconds (one-way)
# Source: SimBlock paper, based on Bitcoin network measurements circa 2019
INTER_REGION_LATENCY_MS: Dict[Tuple[Region, Region], float] = {
    # Same region
    (Region.NORTH_AMERICA, Region.NORTH_AMERICA): 32,
    (Region.EUROPE, Region.EUROPE): 12,
    (Region.ASIA, Region.ASIA): 70,
    (Region.JAPAN, Region.JAPAN): 2,
    (Region.AUSTRALIA, Region.AUSTRALIA): 56,
    (Region.SOUTH_AMERICA, Region.SOUTH_AMERICA): 85,

    # Cross-region (symmetric - we store both directions)
    (Region.NORTH_AMERICA, Region.EUROPE): 124,
    (Region.EUROPE, Region.NORTH_AMERICA): 124,

    (Region.NORTH_AMERICA, Region.ASIA): 252,
    (Region.ASIA, Region.NORTH_AMERICA): 252,

    (Region.NORTH_AMERICA, Region.JAPAN): 151,
    (Region.JAPAN, Region.NORTH_AMERICA): 151,

    (Region.NORTH_AMERICA, Region.AUSTRALIA): 189,
    (Region.AUSTRALIA, Region.NORTH_AMERICA): 189,

    (Region.NORTH_AMERICA, Region.SOUTH_AMERICA): 162,
    (Region.SOUTH_AMERICA, Region.NORTH_AMERICA): 162,

    (Region.EUROPE, Region.ASIA): 268,
    (Region.ASIA, Region.EUROPE): 268,

    (Region.EUROPE, Region.JAPAN): 287,
    (Region.JAPAN, Region.EUROPE): 287,

    (Region.EUROPE, Region.AUSTRALIA): 350,
    (Region.AUSTRALIA, Region.EUROPE): 350,

    (Region.EUROPE, Region.SOUTH_AMERICA): 221,
    (Region.SOUTH_AMERICA, Region.EUROPE): 221,

    (Region.ASIA, Region.JAPAN): 42,
    (Region.JAPAN, Region.ASIA): 42,

    (Region.ASIA, Region.AUSTRALIA): 120,
    (Region.AUSTRALIA, Region.ASIA): 120,

    (Region.ASIA, Region.SOUTH_AMERICA): 340,
    (Region.SOUTH_AMERICA, Region.ASIA): 340,

    (Region.JAPAN, Region.AUSTRALIA): 130,
    (Region.AUSTRALIA, Region.JAPAN): 130,

    (Region.JAPAN, Region.SOUTH_AMERICA): 290,
    (Region.SOUTH_AMERICA, Region.JAPAN): 290,

    (Region.AUSTRALIA, Region.SOUTH_AMERICA): 322,
    (Region.SOUTH_AMERICA, Region.AUSTRALIA): 322,
}


def get_inter_region_latency(region_a: Region, region_b: Region) -> float:
    """Get base latency between two regions in milliseconds."""
    key = (region_a, region_b)
    if key in INTER_REGION_LATENCY_MS:
        return INTER_REGION_LATENCY_MS[key]
    raise ValueError(f"No latency data for {region_a} <-> {region_b}")
