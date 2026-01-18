"""
Assertion Evaluator

Evaluates trace assertions against simulation results.
"""

from dataclasses import dataclass
from typing import Any, Dict, List

from ..traces.schema import TraceAssertion
from .registry import ASSERTION_HANDLERS


@dataclass
class AssertionResult:
    """Result of evaluating a single assertion."""
    assertion_type: str
    description: str
    passed: bool
    message: str

    def __str__(self) -> str:
        status = "PASS" if self.passed else "FAIL"
        return f"[{status}] {self.description}: {self.message}"


def evaluate_assertion(
    assertion: TraceAssertion,
    state: Dict[str, Any],
) -> AssertionResult:
    """
    Evaluate a single assertion against simulation state.

    Args:
        assertion: The assertion to evaluate
        state: Current simulation state (agents, messages, etc.)

    Returns:
        AssertionResult with pass/fail status
    """
    assertion_type = assertion.type
    handler = ASSERTION_HANDLERS.get(assertion_type)

    if handler is None:
        return AssertionResult(
            assertion_type=assertion_type,
            description=assertion.description,
            passed=False,
            message=f"Unknown assertion type: {assertion_type}",
        )

    try:
        passed, message = handler(assertion.params, state)
        return AssertionResult(
            assertion_type=assertion_type,
            description=assertion.description,
            passed=passed,
            message=message,
        )
    except Exception as e:
        return AssertionResult(
            assertion_type=assertion_type,
            description=assertion.description,
            passed=False,
            message=f"Error evaluating assertion: {str(e)}",
        )


def evaluate_all_assertions(
    assertions: List[TraceAssertion],
    state: Dict[str, Any],
) -> List[AssertionResult]:
    """
    Evaluate all assertions against simulation state.

    Args:
        assertions: List of assertions to evaluate
        state: Current simulation state

    Returns:
        List of AssertionResults
    """
    return [evaluate_assertion(a, state) for a in assertions]


def assertions_passed(results: List[AssertionResult]) -> bool:
    """Check if all assertions passed."""
    return all(r.passed for r in results)


def format_assertion_results(results: List[AssertionResult]) -> str:
    """Format assertion results for display."""
    lines = ["Assertion Results:"]
    lines.append("-" * 50)

    passed = 0
    failed = 0

    for result in results:
        lines.append(str(result))
        if result.passed:
            passed += 1
        else:
            failed += 1

    lines.append("-" * 50)
    lines.append(f"Total: {passed} passed, {failed} failed")

    return "\n".join(lines)
