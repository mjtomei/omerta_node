#!/usr/bin/env python3
"""
Parser fuzzer for the DSL grammar.

Generates random and mutated inputs to find parser bugs like:
- Crashes (exceptions other than parse errors)
- Hangs (infinite loops)
- Memory issues
- Inconsistent behavior

Usage:
    python scripts/fuzz_parser.py [--duration MINUTES] [--seed SEED]

Findings are saved to scripts/fuzz_findings/
"""

import argparse
import hashlib
import os
import random
import signal
import string
import sys
import time
import traceback
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent))

from lark.exceptions import (
    UnexpectedInput,
    UnexpectedCharacters,
    UnexpectedToken,
    UnexpectedEOF,
    VisitError,
)

from dsl_peg_parser import parse

# Expected parse errors - these are normal rejections
EXPECTED_ERRORS = (
    UnexpectedInput,
    UnexpectedCharacters,
    UnexpectedToken,
    UnexpectedEOF,
    ValueError,  # Type validation errors (e.g., map<> with wrong arg count)
    VisitError,  # Lark wraps transformer errors in VisitError
)

# Directory for saving findings
FINDINGS_DIR = Path(__file__).parent / "fuzz_findings"


class TimeoutError(Exception):
    pass


@contextmanager
def timeout(seconds):
    """Context manager for timeout on Unix systems."""
    def handler(signum, frame):
        raise TimeoutError(f"Timed out after {seconds} seconds")

    if hasattr(signal, 'SIGALRM'):
        old_handler = signal.signal(signal.SIGALRM, handler)
        signal.alarm(seconds)
        try:
            yield
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old_handler)
    else:
        # Windows fallback - no timeout
        yield


class Fuzzer:
    """DSL parser fuzzer."""

    # Token pools for generation
    KEYWORDS = [
        "transaction", "imports", "parameters", "enum", "message", "block",
        "actor", "function", "native", "from", "to", "by", "signed", "store",
        "trigger", "state", "initial", "terminal", "auto", "on", "timeout",
        "when", "else", "lookup", "SEND", "BROADCAST", "APPEND", "STORE",
        "return", "RETURN", "FOR", "IN", "IF", "THEN", "ELSE", "and", "or",
        "not", "true", "false", "null",
    ]

    OPERATORS = ["->", "=>", "==", "!=", "<=", ">=", "<", ">", "+", "-", "*", "/", ".", ",", ":", "="]
    BRACKETS = ["(", ")", "[", "]", "{", "}"]

    TYPES = ["uint", "int", "string", "hash", "bool", "timestamp", "peer_id", "any", "dict"]
    IDENTIFIERS = ["x", "y", "z", "foo", "bar", "baz", "A", "B", "C", "MSG", "BLOCK", "Consumer", "Provider"]

    # Seed corpus - known valid inputs
    SEED_CORPUS = [
        'transaction 01 "Test"',
        'transaction 01 "Test" "Description"',
        'imports shared/common',
        'parameters ( TIMEOUT = 300 seconds )',
        'parameters ( RATIO = 0.67 )',
        'enum Status ( PENDING  ACTIVE  DONE )',
        'enum Status "A status" ( PENDING  ACTIVE )',
        'message MSG from A to [B] ( x hash )',
        'message MSG from A to [B, C] signed ( x hash  y uint )',
        'block BLK by [A] ( x hash )',
        'block BLK by [A, B] ( x hash  y uint )',
        'actor A ( state S initial )',
        'actor A ( state S initial  state T terminal )',
        'actor A ( state S initial  S -> S auto )',
        'actor A ( state S initial  S -> S on MSG )',
        'actor A ( state S initial  S -> S on timeout(T) )',
        'actor A ( state S initial  state T  S -> T auto when x > 0 )',
        'actor A ( state S initial  state T  S -> T auto when x > 0 else -> S )',
        'actor A ( state S initial  S -> S auto ( store x ) )',
        'actor A ( state S initial  S -> S auto ( x = 1 ) )',
        'actor A ( state S initial  S -> S auto ( SEND(msg, target) ) )',
        'actor A ( state S initial  S -> S auto ( APPEND(list, item) ) )',
        'actor A ( store ( x hash ) state S initial )',
        'actor A ( trigger start() in [S] state S initial )',
        'function f() -> uint ( return 1 )',
        'function f(x uint) -> uint ( return x )',
        'function f(x uint, y uint) -> uint ( return x + y )',
        'function f() -> list<uint> ( return [1, 2, 3] )',
        'function f() -> uint ( return IF x THEN 1 ELSE 2 )',
        'function f() -> uint ( FOR x IN list return x )',
        'function f() -> uint ( return FILTER(list, x => x > 0) )',
        'function f() -> uint ( return {a: 1, b: 2} )',
        'function f() -> uint ( return {...base, x: 1} )',
        'function f() -> uint ( return a.b.c )',
        'function f() -> uint ( return a[0][1] )',
        'function f() -> uint ( return f(g(h(x))) )',
        'native function f() -> uint "impl"',
    ]

    def __init__(self, seed=None):
        self.rng = random.Random(seed)
        self.stats = {
            "iterations": 0,
            "parse_ok": 0,
            "parse_error": 0,
            "crashes": 0,
            "timeouts": 0,
            "unique_crashes": set(),
        }
        self.start_time = None

        # Create findings directory
        FINDINGS_DIR.mkdir(exist_ok=True)

    def random_identifier(self) -> str:
        """Generate a random identifier."""
        if self.rng.random() < 0.7:
            return self.rng.choice(self.IDENTIFIERS)
        length = self.rng.randint(1, 20)
        first = self.rng.choice(string.ascii_letters + "_")
        rest = "".join(self.rng.choices(string.ascii_letters + string.digits + "_", k=length-1))
        return first + rest

    def random_number(self) -> str:
        """Generate a random number."""
        if self.rng.random() < 0.3:
            return str(self.rng.randint(-1000, 1000))
        elif self.rng.random() < 0.5:
            return f"{self.rng.uniform(-100, 100):.2f}"
        else:
            # Edge cases
            return self.rng.choice(["0", "-0", "0.0", "999999999999", "-1", "0.001"])

    def random_string(self) -> str:
        """Generate a random string literal."""
        if self.rng.random() < 0.1:
            # Edge case strings
            return self.rng.choice(['""', '"test"', '" "', '"a b c"', '"123"'])
        length = self.rng.randint(0, 50)
        # Avoid quotes and newlines (which should be rejected)
        chars = "".join(self.rng.choices(string.printable.replace('"', '').replace('\n', '').replace('\r', ''), k=length))
        return f'"{chars}"'

    def random_type(self) -> str:
        """Generate a random type expression."""
        base = self.rng.choice(self.TYPES + self.IDENTIFIERS[:3])
        if self.rng.random() < 0.3:
            inner = self.random_type() if self.rng.random() < 0.3 else self.rng.choice(self.TYPES)
            return f"list<{inner}>"
        elif self.rng.random() < 0.2:
            k = self.rng.choice(self.TYPES)
            v = self.rng.choice(self.TYPES)
            return f"map<{k}, {v}>"
        return base

    def random_expr(self, depth=0) -> str:
        """Generate a random expression."""
        if depth > 5 or self.rng.random() < 0.3:
            # Base cases
            choice = self.rng.randint(0, 4)
            if choice == 0:
                return self.random_identifier()
            elif choice == 1:
                return self.random_number()
            elif choice == 2:
                return self.rng.choice(["true", "false", "null"])
            elif choice == 3:
                return self.random_string()
            else:
                return f"{self.random_identifier()}.{self.random_identifier()}"

        # Recursive cases
        choice = self.rng.randint(0, 10)
        if choice == 0:
            # Binary op
            op = self.rng.choice(["+", "-", "*", "/", "==", "!=", "<", ">", "and", "or"])
            return f"({self.random_expr(depth+1)} {op} {self.random_expr(depth+1)})"
        elif choice == 1:
            # Function call
            args = ", ".join(self.random_expr(depth+1) for _ in range(self.rng.randint(0, 3)))
            return f"{self.random_identifier()}({args})"
        elif choice == 2:
            # Field access
            return f"{self.random_expr(depth+1)}.{self.random_identifier()}"
        elif choice == 3:
            # Index access
            return f"{self.random_expr(depth+1)}[{self.random_expr(depth+1)}]"
        elif choice == 4:
            # List literal
            items = ", ".join(self.random_expr(depth+1) for _ in range(self.rng.randint(0, 4)))
            return f"[{items}]"
        elif choice == 5:
            # Struct literal
            num_fields = self.rng.randint(0, 3)
            fields = ", ".join(f"{self.random_identifier()} {self.random_expr(depth+1)}"
                              for _ in range(num_fields))
            return f"{{{fields}}}"
        elif choice == 6:
            # Lambda
            return f"{self.random_identifier()} => {self.random_expr(depth+1)}"
        elif choice == 7:
            # IF expression
            return f"IF {self.random_expr(depth+1)} THEN {self.random_expr(depth+1)} ELSE {self.random_expr(depth+1)}"
        elif choice == 8:
            # Unary
            op = self.rng.choice(["-", "not "])
            return f"{op}{self.random_expr(depth+1)}"
        elif choice == 9:
            # Grouped
            return f"({self.random_expr(depth+1)})"
        else:
            # Spread in struct
            return f"{{...{self.random_identifier()}}}"

    def generate_random(self) -> str:
        """Generate a completely random input."""
        parts = []
        num_decls = self.rng.randint(1, 5)

        for _ in range(num_decls):
            decl_type = self.rng.randint(0, 7)

            if decl_type == 0:
                # Transaction
                parts.append(f'transaction {self.rng.randint(0, 99)} {self.random_string()}')
            elif decl_type == 1:
                # Parameters
                params = "  ".join(f"{self.random_identifier()} = {self.random_number()}"
                                   for _ in range(self.rng.randint(0, 3)))
                parts.append(f"parameters ( {params} )")
            elif decl_type == 2:
                # Enum
                values = "  ".join(self.random_identifier().upper() for _ in range(self.rng.randint(1, 5)))
                parts.append(f"enum {self.random_identifier()} ( {values} )")
            elif decl_type == 3:
                # Message
                fields = "  ".join(f"{self.random_identifier()} {self.random_type()}"
                                   for _ in range(self.rng.randint(0, 4)))
                recipients = ", ".join(self.random_identifier() for _ in range(self.rng.randint(1, 3)))
                signed = "signed " if self.rng.random() < 0.3 else ""
                parts.append(f"message {self.random_identifier().upper()} from {self.random_identifier()} to [{recipients}] {signed}( {fields} )")
            elif decl_type == 4:
                # Actor
                body_parts = []
                # States
                for i in range(self.rng.randint(1, 3)):
                    mods = ""
                    if i == 0:
                        mods = "initial"
                    elif self.rng.random() < 0.3:
                        mods = "terminal"
                    body_parts.append(f"state S{i} {mods}")
                # Transitions
                for _ in range(self.rng.randint(0, 2)):
                    trigger = self.rng.choice(["auto", f"on {self.random_identifier().upper()}", "on timeout(T)"])
                    body_parts.append(f"S0 -> S0 {trigger}")
                parts.append(f"actor {self.random_identifier()} ( {' '.join(body_parts)} )")
            elif decl_type == 5:
                # Function
                params = ", ".join(f"{self.random_identifier()} {self.random_type()}"
                                   for _ in range(self.rng.randint(0, 3)))
                parts.append(f"function {self.random_identifier()}({params}) -> {self.random_type()} ( return {self.random_expr()} )")
            elif decl_type == 6:
                # Block
                fields = "  ".join(f"{self.random_identifier()} {self.random_type()}"
                                   for _ in range(self.rng.randint(0, 3)))
                signers = ", ".join(self.random_identifier() for _ in range(self.rng.randint(1, 2)))
                parts.append(f"block {self.random_identifier().upper()} by [{signers}] ( {fields} )")
            else:
                # Import
                path = "/".join(self.random_identifier() for _ in range(self.rng.randint(1, 3)))
                parts.append(f"imports {path}")

        return "\n".join(parts)

    def mutate(self, input_str: str) -> str:
        """Mutate an input string."""
        mutations = [
            self._mutate_insert_random,
            self._mutate_delete_chunk,
            self._mutate_swap_chunks,
            self._mutate_repeat_chunk,
            self._mutate_flip_char,
            self._mutate_insert_special,
            self._mutate_boundary_numbers,
        ]

        mutation = self.rng.choice(mutations)
        return mutation(input_str)

    def _mutate_insert_random(self, s: str) -> str:
        """Insert random characters."""
        pos = self.rng.randint(0, len(s))
        chars = self.rng.choice([
            self.rng.choice(self.KEYWORDS),
            self.rng.choice(self.OPERATORS),
            self.rng.choice(self.BRACKETS),
            self.random_identifier(),
            self.random_number(),
            " " * self.rng.randint(1, 5),
            "\n",
            "\t",
        ])
        return s[:pos] + chars + s[pos:]

    def _mutate_delete_chunk(self, s: str) -> str:
        """Delete a random chunk."""
        if len(s) < 2:
            return s
        start = self.rng.randint(0, len(s) - 1)
        end = self.rng.randint(start + 1, min(start + 20, len(s)))
        return s[:start] + s[end:]

    def _mutate_swap_chunks(self, s: str) -> str:
        """Swap two chunks."""
        if len(s) < 4:
            return s
        mid = len(s) // 2
        return s[mid:] + s[:mid]

    def _mutate_repeat_chunk(self, s: str) -> str:
        """Repeat a chunk."""
        if len(s) < 2:
            return s * 2
        start = self.rng.randint(0, len(s) - 1)
        end = self.rng.randint(start + 1, min(start + 10, len(s)))
        chunk = s[start:end]
        return s[:end] + chunk * self.rng.randint(1, 5) + s[end:]

    def _mutate_flip_char(self, s: str) -> str:
        """Flip a random character."""
        if not s:
            return s
        pos = self.rng.randint(0, len(s) - 1)
        new_char = chr(ord(s[pos]) ^ self.rng.randint(1, 127))
        return s[:pos] + new_char + s[pos+1:]

    def _mutate_insert_special(self, s: str) -> str:
        """Insert special/edge case characters."""
        pos = self.rng.randint(0, len(s))
        special = self.rng.choice([
            "\x00",  # Null
            "\xff",  # High byte
            "\r\n",  # CRLF
            "\t\t\t",  # Tabs
            "🎉",  # Emoji
            "α",  # Unicode
            "\\n",  # Escaped newline literal
            "\\",  # Backslash
            '"',  # Quote
            "'" * 10,  # Many quotes
        ])
        return s[:pos] + special + s[pos:]

    def _mutate_boundary_numbers(self, s: str) -> str:
        """Replace numbers with boundary values."""
        import re
        def replace(m):
            if self.rng.random() < 0.5:
                return self.rng.choice([
                    "0", "-1", "1",
                    "2147483647", "-2147483648",  # INT32 bounds
                    "9999999999999999999999",  # Very large
                    "0.0000000001",  # Very small decimal
                    "-0",
                ])
            return m.group(0)
        return re.sub(r'-?\d+(\.\d+)?', replace, s)

    def save_finding(self, input_str: str, error: Exception, category: str):
        """Save an interesting finding to disk."""
        # Create hash for deduplication
        hash_val = hashlib.md5(input_str.encode('utf-8', errors='replace')).hexdigest()[:8]

        if hash_val in self.stats["unique_crashes"]:
            return

        self.stats["unique_crashes"].add(hash_val)

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = FINDINGS_DIR / f"{category}_{timestamp}_{hash_val}.txt"

        with open(filename, 'w') as f:
            f.write(f"Category: {category}\n")
            f.write(f"Error: {type(error).__name__}: {error}\n")
            f.write(f"Timestamp: {timestamp}\n")
            f.write(f"Input length: {len(input_str)}\n")
            f.write("\n--- Input ---\n")
            f.write(input_str)
            f.write("\n\n--- Traceback ---\n")
            f.write(traceback.format_exc())

        print(f"\n[!] Saved finding: {filename}")

    def test_input(self, input_str: str) -> bool:
        """Test a single input. Returns True if interesting (crash/timeout)."""
        try:
            with timeout(5):  # 5 second timeout
                parse(input_str)
            self.stats["parse_ok"] += 1
            return False
        except EXPECTED_ERRORS:
            # Normal parse rejection
            self.stats["parse_error"] += 1
            return False
        except TimeoutError as e:
            self.stats["timeouts"] += 1
            self.save_finding(input_str, e, "timeout")
            return True
        except Exception as e:
            # Unexpected crash!
            self.stats["crashes"] += 1
            self.save_finding(input_str, e, "crash")
            return True

    def run(self, duration_minutes: float = None):
        """Run the fuzzer."""
        self.start_time = time.time()
        end_time = self.start_time + (duration_minutes * 60) if duration_minutes else None

        print(f"Starting fuzzer (seed corpus: {len(self.SEED_CORPUS)} inputs)")
        print(f"Duration: {'unlimited' if not duration_minutes else f'{duration_minutes} minutes'}")
        print(f"Findings directory: {FINDINGS_DIR}")
        print("-" * 60)

        corpus = list(self.SEED_CORPUS)

        try:
            while True:
                self.stats["iterations"] += 1

                # Check time limit
                if end_time and time.time() > end_time:
                    break

                # Choose strategy
                strategy = self.rng.random()

                if strategy < 0.3:
                    # Generate completely random input
                    input_str = self.generate_random()
                elif strategy < 0.7:
                    # Mutate corpus input
                    base = self.rng.choice(corpus)
                    input_str = self.mutate(base)
                    # Sometimes apply multiple mutations
                    for _ in range(self.rng.randint(0, 3)):
                        input_str = self.mutate(input_str)
                else:
                    # Use corpus directly (for baseline)
                    input_str = self.rng.choice(corpus)

                # Test it
                interesting = self.test_input(input_str)

                # Add interesting inputs to corpus (even parse errors can be interesting for mutation)
                if interesting or (self.rng.random() < 0.01 and len(input_str) < 1000):
                    corpus.append(input_str)
                    if len(corpus) > 1000:
                        corpus.pop(self.rng.randint(len(self.SEED_CORPUS), len(corpus) - 1))

                # Progress report
                if self.stats["iterations"] % 1000 == 0:
                    self.print_stats()

        except KeyboardInterrupt:
            print("\n\nInterrupted by user")

        print("\n" + "=" * 60)
        print("Final Statistics:")
        self.print_stats()

    def print_stats(self):
        """Print current statistics."""
        elapsed = time.time() - self.start_time
        rate = self.stats["iterations"] / elapsed if elapsed > 0 else 0

        print(f"[{elapsed:.1f}s] "
              f"iterations={self.stats['iterations']} "
              f"({rate:.0f}/s) | "
              f"ok={self.stats['parse_ok']} "
              f"reject={self.stats['parse_error']} | "
              f"crashes={self.stats['crashes']} "
              f"timeouts={self.stats['timeouts']} "
              f"unique={len(self.stats['unique_crashes'])}")


def main():
    parser = argparse.ArgumentParser(description="Fuzz the DSL parser")
    parser.add_argument("--duration", type=float, default=None,
                        help="Duration in minutes (default: run forever)")
    parser.add_argument("--seed", type=int, default=None,
                        help="Random seed for reproducibility")
    args = parser.parse_args()

    seed = args.seed if args.seed is not None else int(time.time())
    print(f"Random seed: {seed}")

    fuzzer = Fuzzer(seed=seed)
    fuzzer.run(duration_minutes=args.duration)


if __name__ == "__main__":
    main()
