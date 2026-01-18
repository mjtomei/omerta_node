"""
Assertion evaluation module.

Provides functions to evaluate trace assertions against simulation results.
"""

from .evaluator import (
    AssertionResult,
    evaluate_assertion,
    evaluate_all_assertions,
)
from .registry import (
    ASSERTION_HANDLERS,
    register_assertion_handler,
)

__all__ = [
    "AssertionResult",
    "evaluate_assertion",
    "evaluate_all_assertions",
    "ASSERTION_HANDLERS",
    "register_assertion_handler",
]
