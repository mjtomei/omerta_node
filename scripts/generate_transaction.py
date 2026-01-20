#!/usr/bin/env python3
"""
Generate documentation and Python code from transaction definitions.

Usage:
    python generate_transaction.py <tx_dir> [--markdown] [--python] [--output-dir <dir>]

Example:
    python generate_transaction.py docs/protocol/transactions/00_escrow_lock --markdown
    python generate_transaction.py docs/protocol/transactions/00_escrow_lock --python --output-dir simulations/transactions
"""

import argparse
import re
import sys
from pathlib import Path
from textwrap import dedent, indent
from typing import Dict, List, Any, Optional, Set

from dsl_converter import load_transaction_ast
from dsl_ast import (
    Schema, Transaction, Parameter, EnumDecl, MessageDecl, BlockDecl,
    ActorDecl, TriggerDecl, StateDecl, Transition, FunctionDecl,
    StoreAction, ComputeAction, LookupAction, SendAction, BroadcastAction, AppendAction, AppendBlockAction,
    Field, OnGuardFail,
    AssignmentStmt, ReturnStmt, ForStmt, IfStmt, FunctionStatement
)


# =============================================================================
# EXPRESSION TRANSLATOR
# =============================================================================

class ExpressionTranslator:
    """Translate DSL expressions to Python code."""

    # Built-in actor properties (accessed as self.X)
    ACTOR_PROPS = {'peer_id', 'current_time', 'chain', 'state', 'cached_chains'}

    # Built-in functions that map directly (from FORMAT.md)
    BUILTIN_FUNCS = {
        # Cryptographic
        'HASH': 'hash_data',
        'VERIFY_SIG': 'verify_sig',
        'MULTI_SIGN': 'multi_sign',
        'RANDOM_BYTES': 'random_bytes',
        'GENERATE_ID': 'generate_id',
        # Compute
        'LENGTH': 'len',
        'NOW': 'self.current_time',  # Special case - property not function
        # Keep lowercase aliases for compatibility
        'hash': 'hash_data',
        'verify_sig': 'verify_sig',
        'random_bytes': 'random_bytes',
        'len': 'len',
    }

    # Functions that need special expansion (implicit arguments)
    SPECIAL_FUNCS = {
        # SIGN(data) -> sign(self.chain.private_key, hash_data(data))
        'SIGN': 'sign(self.chain.private_key, hash_data({}))',
        'sign': 'sign(self.chain.private_key, hash_data({}))',
    }

    # Functions where argument is a literal key name (not translated)
    LITERAL_KEY_FUNCS = {
        # LOAD(key) -> self.load("key")
        'LOAD': 'self.load("{}")',
    }

    # Functions that need self prefix (protocol-specific built-ins)
    # These require runtime primitives that can't be expressed in pure DSL
    SELF_FUNCS = {
        # Chain operations (need chain object internals)
        'READ': '_read_chain',
        'CHAIN_SEGMENT': '_chain_segment',
        'VERIFY_CHAIN_SEGMENT': '_verify_chain_segment',
        'CHAIN_CONTAINS_HASH': '_chain_contains_hash',
        'CHAIN_STATE_AT': '_chain_state_at',
        # Seeded random (need Python's random module)
        'SEEDED_RNG': '_seeded_rng',
        'SEEDED_SAMPLE': '_seeded_sample',
        # Utilities (need Python primitives or null-safety)
        'SORT': '_sort',
        'ABORT': '_abort',
        'CONCAT': '_concat',
        'HAS_KEY': '_has_key',  # Null-safe dict key check
        # Internal helpers
        '_to_hashable': '_to_hashable',
    }

    def __init__(self, store_vars: Set[str], parameters: Set[str], enums: Dict[str, List[str]]):
        self.store_vars = store_vars
        self.parameters = parameters
        self.enums = enums  # Store full mapping for lookups
        # Build set of enum names (like LockStatus, WitnessVerdict)
        self.enum_names = set(enums.keys())
        # Build set of enum values for recognition
        self.enum_values = set()
        # Build reverse mapping: value -> enum name
        self.value_to_enum = {}
        for enum_name, values in enums.items():
            for val in values:
                self.enum_values.add(val)
                self.value_to_enum[val] = enum_name

    def get_enum_reference(self, value: str) -> Optional[str]:
        """Get enum reference for a value, e.g., 'ACCEPT' -> 'WitnessVerdict.ACCEPT'.

        Also handles fully-qualified references like 'TerminationReason.CONSUMER_REQUEST'.
        """
        # Check for bare enum value
        if value in self.value_to_enum:
            return f"{self.value_to_enum[value]}.{value}"
        # Check for fully-qualified enum reference (EnumName.VALUE)
        if '.' in value:
            parts = value.split('.', 1)
            if len(parts) == 2:
                enum_name, enum_value = parts
                # Verify the enum and value exist
                if enum_value in self.value_to_enum and self.value_to_enum[enum_value] == enum_name:
                    return value  # Already fully-qualified
        return None

    def translate(self, expr: str, local_vars: Set[str] = None) -> str:
        """Translate a DSL expression to Python code.

        Args:
            expr: The DSL expression to translate
            local_vars: Set of variable names that are local (e.g., lambda params)
                       These won't be translated to self.load()
        """
        if not expr:
            return "True"

        self._local_vars = local_vars or set()

        # Normalize whitespace
        expr = " ".join(expr.split())

        # Pre-process: handle struct literals with spread syntax { ...var, field }
        expr = self._preprocess_struct_literal(expr)

        # Pre-process: transform hash(a + b + c) to hash(_to_bytes(a, b, c))
        expr = self._preprocess_hash_concat(expr)

        # Pre-process: handle inline IF expressions (IF cond THEN a ELSE b -> a if cond else b)
        expr = self._preprocess_inline_if(expr)

        # Pre-process: handle FILTER and MAP with lambda expressions
        expr = self._preprocess_filter_map(expr)

        # Pre-process: handle dynamic field access X.{Y} -> X.get(Y)
        expr = self._preprocess_dynamic_field_access(expr)

        # Replace operators
        expr = expr.replace("&&", " and ")
        expr = expr.replace("||", " or ")
        expr = expr.replace("null", "None")

        # Translate function calls and variable references
        result = self._translate_tokens(expr)

        self._local_vars = set()
        return result

    def _preprocess_inline_if(self, expr: str) -> str:
        """Transform DSL inline IF to Python ternary.

        IF condition THEN true_val ELSE false_val -> true_val if condition else false_val

        Handles nested IF expressions by processing innermost first.
        """
        # Process all IF expressions from left to right
        while True:
            # Find IF keyword (case insensitive, word boundary)
            match = re.search(r'\bIF\b', expr, re.IGNORECASE)
            if not match:
                break

            if_start = match.start()

            # Find THEN keyword
            then_match = re.search(r'\bTHEN\b', expr[match.end():], re.IGNORECASE)
            if not then_match:
                # Malformed - no THEN, leave as is
                break
            then_pos = match.end() + then_match.start()
            condition = expr[match.end():then_pos].strip()

            # Find ELSE keyword - need to handle nested IF/THEN/ELSE
            # Count nested IFs to find the matching ELSE
            search_start = then_pos + 4  # len('THEN')
            nesting = 0
            else_pos = -1
            i = search_start
            while i < len(expr):
                # Check for IF
                if_match = re.match(r'\bIF\b', expr[i:], re.IGNORECASE)
                if if_match:
                    nesting += 1
                    i += 2
                    continue
                # Check for ELSE
                else_match = re.match(r'\bELSE\b', expr[i:], re.IGNORECASE)
                if else_match:
                    if nesting == 0:
                        else_pos = i
                        break
                    else:
                        nesting -= 1
                        i += 4
                        continue
                i += 1

            if else_pos == -1:
                # Malformed - no matching ELSE, leave as is
                break

            then_val = expr[search_start:else_pos].strip()
            else_start = else_pos + 4  # len('ELSE')

            # Find the end of the else expression - either end of string or end of current expression context
            # For simplicity, we take everything until end or next statement boundary
            # Check for balanced parens/brackets
            depth = 0
            end_pos = len(expr)
            for j in range(else_start, len(expr)):
                c = expr[j]
                if c in '([{':
                    depth += 1
                elif c in ')]}':
                    if depth > 0:
                        depth -= 1
                    else:
                        # Unmatched close - this is our boundary
                        end_pos = j
                        break
                elif c == ',' and depth == 0:
                    # Top-level comma - boundary
                    end_pos = j
                    break

            else_val = expr[else_start:end_pos].strip()

            # Build Python ternary: true_val if condition else false_val
            replacement = f"({then_val} if {condition} else {else_val})"
            expr = expr[:if_start] + replacement + expr[end_pos:]

        return expr

    def _preprocess_filter_map(self, expr: str) -> str:
        """Transform FILTER/MAP with lambda to Python list comprehensions.

        FILTER(list, v => condition) -> __FILTER_COMP__(list, v, condition)
        MAP(list, v => transform) -> __MAP_COMP__(list, v, transform)

        These markers are then handled specially in _translate_tokens.
        """
        import re

        result = expr
        # Keep processing until no more matches (handles nested cases)
        for _ in range(10):  # Safety limit
            match = re.search(r'\b(FILTER|MAP|filter|map)\s*\(', result)
            if not match:
                break

            func = match.group(1).upper()
            start = match.end() - 1  # Position of opening paren

            # Find the matching closing paren
            depth = 1
            i = start + 1
            while i < len(result) and depth > 0:
                if result[i] == '(':
                    depth += 1
                elif result[i] == ')':
                    depth -= 1
                i += 1

            if depth != 0:
                break  # Unbalanced

            args_str = result[start+1:i-1]  # Content between parens

            # Split on first comma to get list and lambda
            comma_pos = self._find_first_comma(args_str)
            if comma_pos == -1:
                break

            list_expr = args_str[:comma_pos].strip()
            lambda_expr = args_str[comma_pos+1:].strip()

            # Parse lambda: var => body
            arrow_pos = lambda_expr.find('=>')
            if arrow_pos == -1:
                # Not a lambda - might be a predicate variable
                break

            var_name = lambda_expr[:arrow_pos].strip()
            body = lambda_expr[arrow_pos+2:].strip()

            # Create marker that will be expanded in _translate_tokens
            if func == 'FILTER':
                replacement = f'__FILTER_COMP__({list_expr}, {var_name}, {body})'
            else:
                replacement = f'__MAP_COMP__({list_expr}, {var_name}, {body})'

            result = result[:match.start()] + replacement + result[i:]

        return result

    def _find_first_comma(self, s: str) -> int:
        """Find first comma at depth 0 (not inside parens/brackets)."""
        depth = 0
        for i, c in enumerate(s):
            if c in '([{':
                depth += 1
            elif c in ')]}':
                depth -= 1
            elif c == ',' and depth == 0:
                return i
        return -1

    def _preprocess_dynamic_field_access(self, expr: str) -> str:
        """Transform dynamic field access X.{Y} to __DYNAMIC_GET__(X, Y).

        In the DSL, r.{field} means "get field named by variable 'field' from r".
        """
        import re
        # Pattern: identifier followed by .{ identifier }
        # e.g., r.{field} -> __DYNAMIC_GET__(r, field)
        pattern = r'(\w+)\.\{(\w+)\}'
        return re.sub(pattern, r'__DYNAMIC_GET__(\1, \2)', expr)

    def _preprocess_struct_literal(self, expr: str) -> str:
        """
        Handle struct literal syntax: { ...spread_var, field1, field2: value }.

        Transforms:
        - { ...base, field } → __STRUCT_SPREAD__(base, field)
        - { a, b, c } → __STRUCT__(a, b, c)

        These markers are handled by _translate_tokens and converted to proper Python.
        """
        # Check if expression is a struct literal (starts with { and ends with })
        stripped = expr.strip()
        if not (stripped.startswith('{') and stripped.endswith('}')):
            return expr

        # Check if it looks like a struct literal (has commas and no '=>')
        # We need to distinguish from code blocks
        inner = stripped[1:-1].strip()
        if not inner or '=>' in inner:
            return expr  # It's a lambda or something else

        # Parse the struct literal
        parts = []
        current = []
        depth = 0
        for char in inner:
            if char == ',' and depth == 0:
                parts.append(''.join(current).strip())
                current = []
            else:
                current.append(char)
                if char in '({[':
                    depth += 1
                elif char in ')}]':
                    depth -= 1
        if current:
            parts.append(''.join(current).strip())

        # Check for spread syntax
        spread_var = None
        fields = []
        for part in parts:
            part = part.strip()
            if part.startswith('...'):
                spread_var = part[3:].strip()
            else:
                fields.append(part)

        # Build marker expression
        if spread_var:
            if fields:
                return f'__STRUCT_SPREAD__({spread_var}, {", ".join(fields)})'
            else:
                return f'__STRUCT_SPREAD__({spread_var})'
        else:
            return f'__STRUCT__({", ".join(fields)})'

    def _preprocess_hash_concat(self, expr: str) -> str:
        """Transform HASH(a + b + c) to HASH(_to_hashable(a, b, c))."""
        # Find standalone HASH(...) or hash(...) patterns and replace + inside with ,
        result = []
        i = 0
        while i < len(expr):
            # Look for 'HASH(' or 'hash(' but not as part of another word
            if expr[i:i+5].upper() == 'HASH(':
                # Check it's not part of another identifier (e.g., CHAIN_CONTAINS_HASH)
                if i > 0 and (expr[i-1].isalnum() or expr[i-1] == '_'):
                    result.append(expr[i])
                    i += 1
                    continue
                result.append('HASH(_to_hashable(')
                i += 5
                # Find matching )
                depth = 1
                start = i
                while i < len(expr) and depth > 0:
                    if expr[i] == '(':
                        depth += 1
                    elif expr[i] == ')':
                        depth -= 1
                    i += 1
                # Extract contents and replace + with ,
                contents = expr[start:i-1]
                contents = contents.replace(' + ', ', ')
                result.append(contents)
                result.append('))')
            else:
                result.append(expr[i])
                i += 1
        return ''.join(result)

    def _translate_tokens(self, expr: str) -> str:
        """Translate individual tokens in the expression."""
        result = []
        i = 0

        while i < len(expr):
            # Skip whitespace
            if expr[i].isspace():
                result.append(expr[i])
                i += 1
                continue

            # Handle operators and punctuation
            if expr[i] in '()[]{},:+-*/<>=!':
                # Check for multi-char operators
                if i + 1 < len(expr) and expr[i:i+2] in ('==', '!=', '>=', '<='):
                    result.append(expr[i:i+2])
                    i += 2
                else:
                    result.append(expr[i])
                    i += 1
                continue

            # Handle string literals
            if expr[i] in '"\'':
                quote = expr[i]
                j = i + 1
                while j < len(expr) and expr[j] != quote:
                    if expr[j] == '\\':
                        j += 2
                    else:
                        j += 1
                result.append(expr[i:j+1])
                i = j + 1
                continue

            # Handle numbers
            if expr[i].isdigit():
                j = i
                while j < len(expr) and (expr[j].isdigit() or expr[j] == '.'):
                    j += 1
                result.append(expr[i:j])
                i = j
                continue

            # Handle identifiers and keywords
            if expr[i].isalpha() or expr[i] == '_':
                j = i
                while j < len(expr) and (expr[j].isalnum() or expr[j] == '_'):
                    j += 1
                token = expr[i:j]

                # Check what follows (for function calls, attribute access)
                rest = expr[j:].lstrip()

                # Handle DSL operators that map to Python keywords (uppercase to lowercase)
                dsl_to_python_ops = {'NOT': 'not', 'AND': 'and', 'OR': 'or'}
                if token in dsl_to_python_ops:
                    result.append(dsl_to_python_ops[token])
                    i = j
                    continue

                # Handle Python keywords that should be preserved
                if token in ('and', 'or', 'not', 'None', 'True', 'False', 'if', 'else', 'for', 'in'):
                    result.append(token)
                    i = j
                    continue

                # Handle store.X prefix
                if token == 'store' and rest.startswith('.'):
                    # Find the attribute name
                    k = j + 1  # skip the dot
                    while k < len(expr) and expr[k].isspace():
                        k += 1
                    m = k
                    while m < len(expr) and (expr[m].isalnum() or expr[m] == '_'):
                        m += 1
                    attr = expr[k:m]
                    result.append(f'self.load("{attr}")')
                    i = m
                    continue

                # Handle keyword arguments: identifier followed by = (but not ==)
                if rest.startswith('=') and not rest.startswith('=='):
                    # This is a keyword argument name - keep it as-is
                    result.append(token)
                    i = j
                    continue

                # Handle function calls
                if rest.startswith('('):
                    # Handle struct literal markers from preprocessing
                    if token == '__STRUCT__':
                        # __STRUCT__(a, b, c) → {"a": self.load("a"), "b": self.load("b"), ...}
                        paren_start = j
                        while paren_start < len(expr) and expr[paren_start] != '(':
                            paren_start += 1
                        paren_start += 1
                        depth = 1
                        paren_end = paren_start
                        while paren_end < len(expr) and depth > 0:
                            if expr[paren_end] == '(':
                                depth += 1
                            elif expr[paren_end] == ')':
                                depth -= 1
                            paren_end += 1
                        args = expr[paren_start:paren_end-1]
                        # Parse comma-separated field names
                        fields = [f.strip() for f in args.split(',') if f.strip()]
                        dict_parts = []
                        for field in fields:
                            if ':' in field:
                                # key: value pair
                                key, val = field.split(':', 1)
                                key = key.strip()
                                val = val.strip()
                                translated_val = self._translate_tokens(val)
                                dict_parts.append(f'"{key}": {translated_val}')
                            else:
                                # shorthand: field → "field": self.load("field")
                                translated_field = self._translate_tokens(field)
                                dict_parts.append(f'"{field}": {translated_field}')
                        result.append('{' + ', '.join(dict_parts) + '}')
                        i = paren_end
                        continue
                    elif token == '__STRUCT_SPREAD__':
                        # __STRUCT_SPREAD__(base, field1, field2) → {**self.load("base"), "field1": ..., ...}
                        paren_start = j
                        while paren_start < len(expr) and expr[paren_start] != '(':
                            paren_start += 1
                        paren_start += 1
                        depth = 1
                        paren_end = paren_start
                        while paren_end < len(expr) and depth > 0:
                            if expr[paren_end] == '(':
                                depth += 1
                            elif expr[paren_end] == ')':
                                depth -= 1
                            paren_end += 1
                        args = expr[paren_start:paren_end-1]
                        # First arg is spread base, rest are fields
                        parts = [p.strip() for p in args.split(',') if p.strip()]
                        if parts:
                            spread_base = parts[0]
                            fields = parts[1:]
                            spread_translated = self._translate_tokens(spread_base)
                            dict_parts = [f'**{spread_translated}']
                            for field in fields:
                                if ':' in field:
                                    key, val = field.split(':', 1)
                                    key = key.strip()
                                    val = val.strip()
                                    translated_val = self._translate_tokens(val)
                                    dict_parts.append(f'"{key}": {translated_val}')
                                else:
                                    translated_field = self._translate_tokens(field)
                                    dict_parts.append(f'"{field}": {translated_field}')
                            result.append('{' + ', '.join(dict_parts) + '}')
                        i = paren_end
                        continue
                    elif token in ('__FILTER_COMP__', '__MAP_COMP__'):
                        # __FILTER_COMP__(list, var, condition) -> [var for var in list if condition]
                        # __MAP_COMP__(list, var, transform) -> [transform for var in list]
                        paren_start = j
                        while paren_start < len(expr) and expr[paren_start] != '(':
                            paren_start += 1
                        paren_start += 1
                        depth = 1
                        paren_end = paren_start
                        while paren_end < len(expr) and depth > 0:
                            if expr[paren_end] == '(':
                                depth += 1
                            elif expr[paren_end] == ')':
                                depth -= 1
                            paren_end += 1
                        args = expr[paren_start:paren_end-1]
                        # Parse the three arguments: list, var, body
                        comma1 = self._find_first_comma(args)
                        if comma1 != -1:
                            list_expr = args[:comma1].strip()
                            rest = args[comma1+1:]
                            comma2 = self._find_first_comma(rest)
                            if comma2 != -1:
                                var_name = rest[:comma2].strip()
                                body_expr = rest[comma2+1:].strip()

                                # Translate list expression (without var as local)
                                list_translated = self._translate_tokens(list_expr)

                                # Translate body expression with var as local
                                old_locals = getattr(self, '_local_vars', set())
                                self._local_vars = old_locals | {var_name}
                                body_translated = self._translate_tokens(body_expr)
                                self._local_vars = old_locals

                                if token == '__FILTER_COMP__':
                                    result.append(f'[{var_name} for {var_name} in {list_translated} if {body_translated}]')
                                else:  # __MAP_COMP__
                                    result.append(f'[{body_translated} for {var_name} in {list_translated}]')
                                i = paren_end
                                continue
                        # Fallback if parsing failed
                        result.append(token)
                        i = j
                        continue
                    elif token == '__DYNAMIC_GET__':
                        # __DYNAMIC_GET__(obj, field) -> obj.get(field)
                        paren_start = j
                        while paren_start < len(expr) and expr[paren_start] != '(':
                            paren_start += 1
                        paren_start += 1
                        depth = 1
                        paren_end = paren_start
                        while paren_end < len(expr) and depth > 0:
                            if expr[paren_end] == '(':
                                depth += 1
                            elif expr[paren_end] == ')':
                                depth -= 1
                            paren_end += 1
                        args = expr[paren_start:paren_end-1]
                        comma_pos = self._find_first_comma(args)
                        if comma_pos != -1:
                            obj_expr = args[:comma_pos].strip()
                            field_expr = args[comma_pos+1:].strip()
                            obj_translated = self._translate_tokens(obj_expr)
                            field_translated = self._translate_tokens(field_expr)
                            result.append(f'{obj_translated}.get({field_translated})')
                            i = paren_end
                            continue
                        result.append(token)
                        i = j
                        continue
                    # Check for literal key functions (argument is NOT translated)
                    elif token in self.LITERAL_KEY_FUNCS:
                        # Find the matching closing paren
                        paren_start = j
                        while paren_start < len(expr) and expr[paren_start] != '(':
                            paren_start += 1
                        if paren_start < len(expr):
                            paren_start += 1  # skip '('
                            depth = 1
                            paren_end = paren_start
                            while paren_end < len(expr) and depth > 0:
                                if expr[paren_end] == '(':
                                    depth += 1
                                elif expr[paren_end] == ')':
                                    depth -= 1
                                paren_end += 1
                            # Extract argument WITHOUT translation (keep as literal key)
                            arg_expr = expr[paren_start:paren_end-1].strip()
                            # Apply the template with literal key
                            template = self.LITERAL_KEY_FUNCS[token]
                            result.append(template.format(arg_expr))
                            i = paren_end
                            continue
                    # Check for special functions that need argument expansion
                    elif token in self.SPECIAL_FUNCS:
                        # Find the matching closing paren
                        paren_start = j
                        while paren_start < len(expr) and expr[paren_start] != '(':
                            paren_start += 1
                        if paren_start < len(expr):
                            paren_start += 1  # skip '('
                            depth = 1
                            paren_end = paren_start
                            while paren_end < len(expr) and depth > 0:
                                if expr[paren_end] == '(':
                                    depth += 1
                                elif expr[paren_end] == ')':
                                    depth -= 1
                                paren_end += 1
                            # Extract and translate the argument
                            arg_expr = expr[paren_start:paren_end-1]
                            translated_arg = self._translate_tokens(arg_expr)
                            # Apply the template
                            template = self.SPECIAL_FUNCS[token]
                            result.append(template.format(translated_arg))
                            i = paren_end
                            continue
                    elif token in self.BUILTIN_FUNCS:
                        translated = self.BUILTIN_FUNCS[token]
                        # Special case: NOW() -> self.current_time (property, not method)
                        # We need to consume the () but not include them in output
                        if token == 'NOW':
                            # Find and skip the () - NOW is always called as NOW()
                            paren_start = j
                            while paren_start < len(expr) and expr[paren_start] != '(':
                                paren_start += 1
                            if paren_start < len(expr):
                                paren_start += 1  # skip '('
                                depth = 1
                                paren_end = paren_start
                                while paren_end < len(expr) and depth > 0:
                                    if expr[paren_end] == '(':
                                        depth += 1
                                    elif expr[paren_end] == ')':
                                        depth -= 1
                                    paren_end += 1
                                # Skip past the closing paren
                                i = paren_end
                            result.append(translated)
                            continue
                        # Special case: HASH with multiple args -> wrap with _to_hashable
                        if token == 'HASH':
                            paren_start = j
                            while paren_start < len(expr) and expr[paren_start] != '(':
                                paren_start += 1
                            if paren_start < len(expr):
                                paren_start += 1  # skip '('
                                depth = 1
                                paren_end = paren_start
                                while paren_end < len(expr) and depth > 0:
                                    if expr[paren_end] == '(':
                                        depth += 1
                                    elif expr[paren_end] == ')':
                                        depth -= 1
                                    paren_end += 1
                                args = expr[paren_start:paren_end-1]
                                # Check if multiple args (comma at depth 0)
                                depth = 0
                                has_comma = False
                                for c in args:
                                    if c == '(':
                                        depth += 1
                                    elif c == ')':
                                        depth -= 1
                                    elif c == ',' and depth == 0:
                                        has_comma = True
                                        break
                                if has_comma:
                                    # Translate args and wrap with _to_hashable
                                    translated_args = self._translate_tokens(args)
                                    result.append(f'hash_data(self._to_hashable({translated_args}))')
                                    i = paren_end
                                    continue
                        result.append(translated)
                    elif token in self.SELF_FUNCS:
                        result.append(f'self.{self.SELF_FUNCS[token]}')
                    else:
                        # Unknown function - keep as is but add self prefix
                        result.append(f'self._{token}')
                    i = j
                    continue

                # Handle enum names followed by .VALUE (e.g., LockStatus.ACCEPTED)
                # Must check before general attribute access
                if token in self.enum_names and rest.startswith('.'):
                    # Get the full enum reference: EnumName.VALUE
                    k = j + 1  # skip the dot
                    while k < len(expr) and expr[k].isspace():
                        k += 1
                    m = k
                    while m < len(expr) and (expr[m].isalnum() or expr[m] == '_'):
                        m += 1
                    if m > k:
                        enum_value = expr[k:m]
                        # Keep as-is: EnumName.VALUE
                        result.append(f'{token}.{enum_value}')
                        i = m
                        continue

                # Handle attribute access on variables (e.g., pending_result.session_id)
                if rest.startswith('.'):
                    # Consume the variable and all attribute accesses
                    # Check local vars first, then actor props, then store vars
                    if hasattr(self, '_local_vars') and token in self._local_vars:
                        base = token
                    elif token in self.ACTOR_PROPS:
                        base = f'self.{token}'
                    else:
                        base = f'self.load("{token}")'
                    k = j
                    # Process chain of .attribute accesses
                    while k < len(expr):
                        # Skip whitespace
                        while k < len(expr) and expr[k].isspace():
                            k += 1
                        # Check for .attribute
                        if k < len(expr) and expr[k] == '.':
                            k += 1  # skip the dot
                            while k < len(expr) and expr[k].isspace():
                                k += 1
                            # Get attribute name
                            m = k
                            while m < len(expr) and (expr[m].isalnum() or expr[m] == '_'):
                                m += 1
                            if m > k:
                                attr = expr[k:m]
                                base = f'{base}.get("{attr}")'
                                k = m
                            else:
                                break
                        else:
                            break
                    result.append(base)
                    i = k
                    continue

                # Handle parameters (constants)
                if token in self.parameters:
                    result.append(token)  # Keep as uppercase constant
                    i = j
                    continue

                # Handle enum values - convert to full enum reference
                if token in self.enum_values:
                    enum_ref = self.get_enum_reference(token)
                    result.append(enum_ref if enum_ref else token)
                    i = j
                    continue

                # Handle actor properties
                if token in self.ACTOR_PROPS:
                    result.append(f'self.{token}')
                    i = j
                    continue

                # Special case: my_chain refers to self.chain
                if token == 'my_chain':
                    result.append('self.chain')
                    i = j
                    continue

                # Handle local variables (lambda params, function params)
                if hasattr(self, '_local_vars') and token in self._local_vars:
                    result.append(token)
                    i = j
                    continue

                # Handle store variables
                if token in self.store_vars:
                    result.append(f'self.load("{token}")')
                    i = j
                    continue

                # Handle boolean literals
                if token.lower() == 'true':
                    result.append('True')
                    i = j
                    continue
                if token.lower() == 'false':
                    result.append('False')
                    i = j
                    continue

                # Unknown identifier - check if it's a local variable first
                if hasattr(self, '_local_vars') and token in self._local_vars:
                    result.append(token)
                else:
                    # Assume it's a store variable
                    result.append(f'self.load("{token}")')
                i = j
                continue

            # Handle '.' followed by identifier as attribute access on dict/object
            if expr[i] == '.':
                # Check if followed by identifier
                j = i + 1
                while j < len(expr) and expr[j].isspace():
                    j += 1
                if j < len(expr) and (expr[j].isalpha() or expr[j] == '_'):
                    # Get the attribute name
                    k = j
                    while k < len(expr) and (expr[k].isalnum() or expr[k] == '_'):
                        k += 1
                    attr = expr[j:k]

                    # Check what precedes - if previous result ends with ')' or ']',
                    # it's a function call or index result (returns dict/object)
                    # Use .get() for dict-like access
                    result_so_far = ''.join(result).rstrip()
                    if result_so_far and result_so_far.endswith((')' , ']')):
                        result.append(f'.get("{attr}")')
                        i = k
                        continue

            # Default: keep character as-is
            result.append(expr[i])
            i += 1

        return ''.join(result)

    def translate_attribute_access(self, expr: str) -> str:
        """Translate X.Y attribute access to dict/object access."""
        # Pattern: identifier.attribute
        pattern = r'(self\.load\("[^"]+"\))\.(\w+)'

        def replace_attr(match):
            base = match.group(1)
            attr = match.group(2)
            return f'{base}.get("{attr}")'

        return re.sub(pattern, replace_attr, expr)


def load_transaction(tx_dir: Path) -> Schema:
    """Load transaction definition from directory (DSL .omt file)."""
    dsl_path = tx_dir / "transaction.omt"
    if dsl_path.exists():
        schema = load_transaction_ast(dsl_path)
        validate_no_object_types(schema)
        return schema

    raise FileNotFoundError(f"Transaction not found: tried {dsl_path}")


def validate_no_object_types(schema: Schema) -> None:
    """Validate that transaction doesn't use 'object' or 'list[object]' types.

    These types are disallowed - use explicit struct types instead.
    """
    errors = []

    # Check messages
    for msg in schema.messages:
        for field in msg.fields:
            if _is_disallowed_type(field.type):
                errors.append(f"messages.{msg.name}.{field.name}: '{field.type}' is not allowed. Use explicit struct types.")

    # Check actors' store
    for actor in schema.actors:
        for field in actor.store:
            if _is_disallowed_type(field.type):
                errors.append(f"actors.{actor.name}.store.{field.name}: '{field.type}' is not allowed. Use explicit struct types.")

    if errors:
        error_msg = "Validation failed - disallowed types found:\n" + "\n".join(f"  - {e}" for e in errors)
        raise ValueError(error_msg)


def _is_disallowed_type(type_str: str) -> bool:
    """Check if a type string is disallowed (object or list[object])."""
    if not isinstance(type_str, str):
        return False
    type_str = type_str.strip()
    if type_str == "object":
        return True
    if type_str == "list[object]":
        return True
    # Also catch quoted versions
    if type_str == '"object"' or type_str == "'object'":
        return True
    return False


def load_commentary(tx_dir: Path) -> str:
    """Load commentary.md from directory."""
    commentary_path = tx_dir / "commentary.md"
    if not commentary_path.exists():
        return ""

    with open(commentary_path) as f:
        return f.read()


# =============================================================================
# MARKDOWN GENERATION
# =============================================================================

def generate_parameters_markdown(schema: Schema) -> str:
    """Generate parameters table markdown."""
    if not schema.parameters:
        return "No parameters defined."

    lines = ["## Parameters\n"]
    lines.append("| Parameter | Value | Description |")
    lines.append("|-----------|-------|-------------|")

    for param in schema.parameters:
        value = param.value
        if param.unit:
            value = f"{value} {param.unit}"
        desc = param.description or ""
        lines.append(f"| `{param.name}` | {value} | {desc} |")

    return "\n".join(lines)


def generate_blocks_markdown(schema: Schema) -> str:
    """Generate block types markdown."""
    if not schema.blocks:
        return "No block types defined."

    lines = ["## Block Types (Chain Records)\n"]
    lines.append("```")

    for block in schema.blocks:
        lines.append(f"{block.name} {{")
        for field in block.fields:
            lines.append(f"  {field.name}: {field.type}")
        lines.append("}\n")

    lines.append("```")
    return "\n".join(lines)


def generate_messages_markdown(schema: Schema) -> str:
    """Generate message types markdown."""
    if not schema.messages:
        return "No messages defined."

    lines = ["## Message Types\n"]
    lines.append("```")

    for msg in schema.messages:
        recipients_str = ", ".join(msg.recipients)
        lines.append(f"# {msg.sender} -> {recipients_str}")
        lines.append(f"{msg.name} {{")

        for field in msg.fields:
            lines.append(f"  {field.name}: {field.type}")

        if msg.signed:
            lines.append(f"  signature: bytes  # signed by {msg.sender.lower()}")

        lines.append("}\n")

    lines.append("```")
    return "\n".join(lines)


def generate_state_machines_markdown(schema: Schema) -> str:
    """Generate state machine diagrams markdown."""
    if not schema.actors:
        return "No actors defined."

    lines = []

    for actor in schema.actors:
        lines.append(f"### ACTOR: {actor.name}\n")
        if actor.description:
            lines.append(f"*{actor.description}*\n")

        lines.append("```")

        # States
        state_names = [s.name for s in actor.states]
        lines.append(f"STATES: [{', '.join(state_names)}]")
        lines.append("")

        # Find initial state
        initial = next((s.name for s in actor.states if s.initial), state_names[0] if state_names else "IDLE")
        lines.append(f"INITIAL: {initial}")
        lines.append("")

        # External triggers
        if actor.triggers:
            lines.append("EXTERNAL TRIGGERS:")
            for trigger in actor.triggers:
                param_str = ", ".join(f"{p.name}: {p.type}" for p in trigger.params)
                lines.append(f"  {trigger.name}({param_str})")
                lines.append(f"    allowed_in: [{', '.join(trigger.allowed_in)}]")
            lines.append("")

        # States with descriptions
        for state in actor.states:
            term_str = " [TERMINAL]" if state.terminal else ""
            lines.append(f"STATE {state.name}:{term_str}")
            if state.description:
                lines.append(f"  # {state.description}")
            lines.append("")

        # Transitions
        if actor.transitions:
            lines.append("TRANSITIONS:")
            for trans in actor.transitions:
                trigger = "auto" if trans.auto else (trans.trigger or "?")
                guard_str = f" [guard: {trans.guard}]" if trans.guard else ""

                lines.append(f"  {trans.from_state} --{trigger}-->{guard_str} {trans.to_state}")

                for action in trans.actions[:3]:
                    action_str = _format_action_for_md(action)
                    if len(action_str) > 60:
                        action_str = action_str[:60] + "..."
                    lines.append(f"    action: {action_str}")

                if len(trans.actions) > 3:
                    lines.append(f"    ... and {len(trans.actions) - 3} more actions")

        lines.append("```\n")

    return "\n".join(lines)


def _format_action_for_md(action) -> str:
    """Format an action for markdown display."""
    if isinstance(action, StoreAction):
        if action.assignments:
            items = list(action.assignments.items())
            if len(items) == 1:
                key, val = items[0]
                return f"STORE({key}, {val})"
            return f"STORE({action.assignments})"
        return f"store {', '.join(action.fields)}"
    elif isinstance(action, ComputeAction):
        return f"compute {action.name} = {action.expression}"
    elif isinstance(action, LookupAction):
        return f"lookup {action.name} = {action.expression}"
    elif isinstance(action, SendAction):
        return f"SEND({action.target}, {action.message})"
    elif isinstance(action, BroadcastAction):
        return f"BROADCAST({action.target_list}, {action.message})"
    elif isinstance(action, AppendAction):
        return f"APPEND({action.list_name}, {action.value})"
    elif isinstance(action, AppendBlockAction):
        return f"APPEND(my_chain, {action.block_type})"
    return str(action)


def generate_markdown(tx_dir: Path, output_path: Path = None) -> str:
    """Generate full markdown documentation from transaction definition."""
    schema = load_transaction(tx_dir)
    commentary = load_commentary(tx_dir)

    params_md = generate_parameters_markdown(schema)
    blocks_md = generate_blocks_markdown(schema)
    messages_md = generate_messages_markdown(schema)
    states_md = generate_state_machines_markdown(schema)

    result = commentary
    result = result.replace("{{PARAMETERS}}", params_md)
    result = result.replace("{{BLOCKS}}", blocks_md)
    result = result.replace("{{MESSAGES}}", messages_md)
    result = result.replace("{{STATE_MACHINES}}", states_md)

    if output_path:
        with open(output_path, "w") as f:
            f.write(result)
        print(f"Generated: {output_path}")

    return result


# =============================================================================
# PYTHON CODE GENERATION
# =============================================================================

def python_type(dsl_type: str) -> str:
    """Convert DSL type to Python type hint."""
    type_map = {
        "hash": "str",
        "peer_id": "str",
        "bytes": "bytes",
        "uint": "int",
        "int": "int",
        "float": "float",
        "timestamp": "float",
        "string": "str",
        "str": "str",
        "bool": "bool",
        "signature": "str",
        "object": "Dict[str, Any]",
        "dict": "Dict[str, Any]",
        "any": "Any",
        "Any": "Any",
        # Generic type parameters - use Any
        "T": "Any",
        "U": "Any",
    }

    # Handle list types with angle brackets (DSL style)
    if dsl_type.startswith("list<"):
        inner = dsl_type[5:-1]
        inner_type = python_type(inner)
        return f"List[{inner_type}]"
    # Handle list types with square brackets (YAML style)
    if dsl_type.startswith("list["):
        inner = dsl_type[5:-1]
        inner_type = python_type(inner)
        return f"List[{inner_type}]"
    # Handle map types with angle brackets
    if dsl_type.startswith("map<"):
        inner = dsl_type[4:-1]
        parts = inner.split(",", 1)
        key = python_type(parts[0].strip())
        val = python_type(parts[1].strip()) if len(parts) > 1 else "Any"
        return f"Dict[{key}, {val}]"
    # Handle map types with square brackets
    if dsl_type.startswith("map["):
        inner = dsl_type[4:-1]
        parts = inner.split(",", 1)
        key = python_type(parts[0].strip())
        val = python_type(parts[1].strip()) if len(parts) > 1 else "Any"
        return f"Dict[{key}, {val}]"

    # Check if it's a known type
    if dsl_type in type_map:
        return type_map[dsl_type]

    # Unknown types (enums, custom types) - use str for enums, Any for others
    # If it looks like an enum (CamelCase), treat as str
    if dsl_type and dsl_type[0].isupper():
        return "str"

    return "Any"


def generate_parameters_python(schema: Schema) -> str:
    """Generate Python parameter constants."""
    if not schema.parameters:
        return ""

    lines = ["# ============================================================================="]
    lines.append("# Parameters")
    lines.append("# =============================================================================")
    lines.append("")

    for param in schema.parameters:
        value = param.value
        if isinstance(value, float) and value == int(value):
            value = int(value)

        comment = f"  # {param.description or ''}"
        if param.unit:
            comment += f" ({param.unit})"

        lines.append(f"{param.name} = {value}{comment}")

    lines.append("")
    return "\n".join(lines)


def generate_enums_python(schema: Schema) -> str:
    """Generate Python enums."""
    if not schema.enums:
        return ""

    lines = ["# ============================================================================="]
    lines.append("# Enums")
    lines.append("# =============================================================================")
    lines.append("")

    for enum in schema.enums:
        lines.append(f"class {enum.name}(Enum):")
        if enum.description:
            lines.append(f'    """{enum.description}"""')
        for val in enum.values:
            lines.append(f"    {val.name} = auto()")
        lines.append("")

    return "\n".join(lines)


def generate_messages_python(schema: Schema) -> str:
    """Generate Python message types."""
    if not schema.messages:
        return ""

    lines = ["# ============================================================================="]
    lines.append("# Message Types")
    lines.append("# =============================================================================")
    lines.append("")
    lines.append("class MessageType(Enum):")
    lines.append('    """Types of messages exchanged in this transaction."""')

    for msg in schema.messages:
        lines.append(f"    {msg.name} = auto()")

    lines.append("")
    lines.append("")
    lines.append("@dataclass")
    lines.append("class Message:")
    lines.append('    """A message between actors."""')
    lines.append("    msg_type: MessageType")
    lines.append("    sender: str")
    lines.append("    payload: Dict[str, Any]")
    lines.append("    timestamp: float")
    lines.append("    recipient: Optional[str] = None  # None means broadcast")
    lines.append("")

    return "\n".join(lines)


class PythonActorGenerator:
    """Generate complete Python actor class from transaction definition."""

    def __init__(self, actor: ActorDecl, schema: Schema):
        self.actor = actor
        self.actor_name = actor.name
        self.schema = schema

        # Build lookup dicts for messages
        self.messages = {msg.name: msg for msg in schema.messages}

        # Collect all known store variable names
        self.store_vars = {field.name for field in actor.store}

        # Create expression translator
        parameters = {param.name for param in schema.parameters}
        enums = {enum.name: [v.name for v in enum.values] for enum in schema.enums}
        self.expr_translator = ExpressionTranslator(self.store_vars, parameters, enums)

    def generate(self) -> str:
        """Generate complete actor class."""
        lines = []

        # State enum
        lines.append(self._generate_state_enum())
        lines.append("")

        # Actor class
        lines.append("@dataclass")
        lines.append(f"class {self.actor_name}(Actor):")

        if self.actor.description:
            lines.append(f'    """{self.actor.description}"""')
        lines.append("")

        # Find initial state
        initial = next((s.name for s in self.actor.states if s.initial), "IDLE")
        lines.append(f"    state: {self.actor_name}State = {self.actor_name}State.{initial}")

        lines.append("")

        # External trigger methods
        for trigger in self.actor.triggers:
            lines.append(self._generate_external_trigger(trigger))
            lines.append("")

        # Tick method
        lines.append(self._generate_tick_method())

        return "\n".join(lines)

    def _is_expression(self, val: str) -> bool:
        """
        Determine if a string value is an expression that should be translated,
        or a literal string that should be stored as-is.

        Expressions include:
        - Arithmetic: "a + b", "x - y", "count * 2"
        - Comparisons: "a >= b", "x == y"
        - Struct literals: "{ a, b, c }"
        - Function calls: "HASH(data)"
        - Variable references: "some_variable"

        String literals include:
        - Error messages with common patterns: "insufficient_balance", "provider_timeout"
        - Status strings: "accept", "reject"
        """
        # Empty string is not an expression
        if not val or not val.strip():
            return False

        val = val.strip()

        # Struct literals start with {
        if val.startswith('{'):
            return True

        # Contains arithmetic/comparison operators (with spaces around them)
        expression_operators = [' + ', ' - ', ' * ', ' / ', ' >= ', ' <= ', ' > ', ' < ', ' == ', ' != ', ' && ', ' || ']
        for op in expression_operators:
            if op in val:
                return True

        # Contains function call syntax
        if '(' in val and ')' in val:
            return True

        # Contains array indexing
        if '[' in val and ']' in val:
            return True

        # Contains dot notation (attribute access)
        if '.' in val:
            return True

        # Check for common error message patterns (these are literal strings)
        # Error messages typically have patterns like: *_timeout, *_mismatch, *_invalid, etc.
        error_suffixes = ('_timeout', '_mismatch', '_invalid', '_error', '_failed', '_rejected', '_missing')
        error_prefixes = ('no_', 'invalid_', 'unknown_', 'insufficient_', 'missing_')
        if any(val.endswith(suffix) for suffix in error_suffixes):
            return False
        if any(val.startswith(prefix) for prefix in error_prefixes):
            return False

        # Simple status words are literals
        status_literals = {'accept', 'reject', 'pending', 'success', 'failure', 'ok', 'error', 'timeout'}
        if val.lower() in status_literals:
            return False

        # If it's a simple identifier (alphanumeric with underscores), treat as expression
        # Variable names include: pending_result, consumer_signature, total_escrowed, etc.
        if val.replace('_', '').isalnum() and val[0].isalpha():
            return True

        return False

    def _generate_state_enum(self) -> str:
        """Generate state enum."""
        lines = [f"class {self.actor_name}State(Enum):"]
        if self.actor.description:
            lines.append(f'    """{self.actor_name} states."""')

        for state in self.actor.states:
            if state.description:
                lines.append(f"    {state.name} = auto()  # {state.description}")
            else:
                lines.append(f"    {state.name} = auto()")

        return "\n".join(lines)

    def _generate_action_code_ast(self, action, indent_level: int, msg_var: str = None) -> List[str]:
        """Generate code for an AST action directly from AST types."""
        from dsl_ast import StoreAction, ComputeAction, LookupAction, SendAction, BroadcastAction, AppendAction, AppendBlockAction

        lines = []
        ind = "    " * indent_level

        if isinstance(action, StoreAction):
            if action.assignments:
                # Store with explicit key=value assignments
                for key, val in action.assignments.items():
                    if isinstance(val, str):
                        # Check for special patterns
                        if val == "message" and msg_var:
                            # Store the entire message payload
                            lines.append(f'{ind}self.store("{key}", {msg_var}.payload)')
                        elif val.startswith("message."):
                            # Expression referencing message
                            msg_attr = val[8:]  # Remove "message." prefix
                            msg = msg_var or "msg"
                            if msg_attr == "payload":
                                # Store the entire payload
                                lines.append(f'{ind}self.store("{key}", {msg}.payload)')
                            elif msg_attr.startswith("payload."):
                                payload_field = msg_attr[8:]
                                lines.append(f'{ind}self.store("{key}", {msg}.payload.get("{payload_field}"))')
                            elif msg_attr == "sender":
                                # Access sender attribute directly
                                lines.append(f'{ind}self.store("{key}", {msg}.sender)')
                            else:
                                # Access other message fields via payload
                                lines.append(f'{ind}self.store("{key}", {msg}.payload.get("{msg_attr}"))')
                        elif val in ExpressionTranslator.ACTOR_PROPS:
                            lines.append(f'{ind}self.store("{key}", self.{val})')
                        elif val in self.store_vars:
                            lines.append(f'{ind}self.store("{key}", self.load("{val}"))')
                        else:
                            enum_ref = self.expr_translator.get_enum_reference(val)
                            if enum_ref:
                                lines.append(f'{ind}self.store("{key}", {enum_ref})')
                            elif self._is_expression(val):
                                translated = self.expr_translator.translate(val)
                                lines.append(f'{ind}self.store("{key}", {translated})')
                            else:
                                # Strip outer quotes if present (DSL string literals)
                                stripped = val
                                if len(val) >= 2 and ((val.startswith('"') and val.endswith('"')) or
                                                       (val.startswith("'") and val.endswith("'"))):
                                    stripped = val[1:-1]
                                lines.append(f'{ind}self.store("{key}", {repr(stripped)})')
                    else:
                        lines.append(f'{ind}self.store("{key}", {repr(val)})')
            elif action.fields:
                # Store fields from params (function arguments) or message
                for field in action.fields:
                    if msg_var:
                        # Message-triggered transition: store from message payload
                        lines.append(f'{ind}self.store("{field}", {msg_var}.payload.get("{field}"))')
                    else:
                        # External trigger: store function argument directly
                        lines.append(f'{ind}self.store("{field}", {field})')

        elif isinstance(action, ComputeAction):
            var_name = action.name
            from_expr = action.expression
            from_expr_oneline = " ".join(str(from_expr).split())
            lines.append(f'{ind}# Compute: {var_name} = {from_expr_oneline}')
            lines.append(f'{ind}self.store("{var_name}", self._compute_{var_name}())')

        elif isinstance(action, LookupAction):
            var_name = action.name
            from_expr = action.expression

            # Special handling for chain.get_peer_hash
            if "get_peer_hash" in from_expr:
                peer_match = re.search(r'get_peer_hash\((\w+)\)', from_expr)
                peer_var = peer_match.group(1) if peer_match else "peer"
                lines.append(f'{ind}_lookup_block = self.chain.get_peer_hash(self.load("{peer_var}"))')
                lines.append(f'{ind}if _lookup_block:')
                lines.append(f'{ind}    self.store("{var_name}", _lookup_block.payload.get("hash"))')
                lines.append(f'{ind}    self.store("{var_name}_timestamp", _lookup_block.timestamp)')
            else:
                translated = self.expr_translator.translate(from_expr)
                lines.append(f'{ind}self.store("{var_name}", {translated})')

        elif isinstance(action, SendAction):
            msg_type = action.message
            to_target = action.target

            # Handle dotted expressions like message.sender
            if to_target.startswith("message."):
                attr = to_target[8:]  # e.g., "sender"
                msg = msg_var or "msg"
                recipient_expr = f'{msg}.{attr}'
            elif to_target in self.store_vars:
                recipient_expr = f'self.load("{to_target}")'
            else:
                recipient_expr = f'self.load("{to_target}")'

            lines.append(f'{ind}msg_payload = self._build_{msg_type.lower()}_payload()')
            lines.append(f'{ind}outgoing.append(Message(')
            lines.append(f'{ind}    msg_type=MessageType.{msg_type},')
            lines.append(f'{ind}    sender=self.peer_id,')
            lines.append(f'{ind}    payload=msg_payload,')
            lines.append(f'{ind}    timestamp=current_time,')
            lines.append(f'{ind}    recipient={recipient_expr},')
            lines.append(f'{ind}))')

        elif isinstance(action, BroadcastAction):
            msg_type = action.message
            target_list = action.target_list

            lines.append(f'{ind}for recipient in self.load("{target_list}", []):')
            lines.append(f'{ind}    msg_payload = self._build_{msg_type.lower()}_payload()')
            lines.append(f'{ind}    outgoing.append(Message(')
            lines.append(f'{ind}        msg_type=MessageType.{msg_type},')
            lines.append(f'{ind}        sender=self.peer_id,')
            lines.append(f'{ind}        payload=msg_payload,')
            lines.append(f'{ind}        timestamp=current_time,')
            lines.append(f'{ind}        recipient=recipient,')
            lines.append(f'{ind}    ))')

        elif isinstance(action, AppendBlockAction):
            block_type = action.block_type
            lines.append(f'{ind}self.chain.append(')
            lines.append(f'{ind}    BlockType.{block_type},')
            lines.append(f'{ind}    self._build_{block_type.lower()}_payload(),')
            lines.append(f'{ind}    current_time,')
            lines.append(f'{ind})')

        elif isinstance(action, AppendAction):
            list_name = action.list_name
            value = action.value

            # Special case: APPEND(my_chain, BLOCK_TYPE) is a chain append
            if list_name == "my_chain":
                block_type = value
                lines.append(f'{ind}self.chain.append(')
                lines.append(f'{ind}    BlockType.{block_type},')
                lines.append(f'{ind}    self._build_{block_type.lower()}_payload(),')
                lines.append(f'{ind}    current_time,')
                lines.append(f'{ind})')
            elif isinstance(value, str):
                if value.startswith("message."):
                    msg_attr = value[8:]
                    msg = msg_var or "msg"
                    lines.append(f'{ind}_list = self.load("{list_name}") or []')
                    if msg_attr.startswith("payload."):
                        payload_field = msg_attr[8:]
                        lines.append(f'{ind}_list.append({msg}.payload.get("{payload_field}"))')
                    elif msg_attr == "payload":
                        lines.append(f'{ind}_list.append({msg}.payload)')
                    else:
                        lines.append(f'{ind}_list.append({msg}.{msg_attr})')
                    lines.append(f'{ind}self.store("{list_name}", _list)')
                elif value in self.store_vars:
                    lines.append(f'{ind}_list = self.load("{list_name}") or []')
                    lines.append(f'{ind}_list.append(self.load("{value}"))')
                    lines.append(f'{ind}self.store("{list_name}", _list)')
                else:
                    lines.append(f'{ind}_list = self.load("{list_name}") or []')
                    lines.append(f'{ind}_list.append({repr(value)})')
                    lines.append(f'{ind}self.store("{list_name}", _list)')
            else:
                lines.append(f'{ind}_list = self.load("{list_name}") or []')
                lines.append(f'{ind}_list.append({repr(value)})')
                lines.append(f'{ind}self.store("{list_name}", _list)')

        return lines

    def _generate_external_trigger(self, trigger: TriggerDecl) -> str:
        """Generate external trigger method."""
        trigger_name = trigger.name
        param_list = ", ".join(f"{p.name}: {python_type(p.type)}" for p in trigger.params)
        allowed_in = trigger.allowed_in

        lines = [f"    def {trigger_name}(self{', ' + param_list if param_list else ''}):"]
        if trigger.description:
            lines.append(f'        """{trigger.description}"""')

        if allowed_in:
            allowed_states = ", ".join(f"{self.actor_name}State.{s}" for s in allowed_in)
            lines.append(f"        if self.state not in ({allowed_states},):")
            lines.append(f'            raise ValueError(f"Cannot {trigger_name} in state {{self.state}}")')
            lines.append("")

        # Find transitions triggered by this external trigger
        for trans in self.actor.transitions:
            if trans.trigger == trigger_name and trans.from_state in allowed_in:
                guard = trans.guard

                # Execute actions first
                for action in trans.actions:
                    lines.extend(self._generate_action_code_ast(action, indent_level=2, msg_var=None))

                # If there's a guard, check it after actions
                if guard:
                    guard_code = self._generate_guard_check(guard)
                    lines.append(f"        if {guard_code}:")
                    if trans.to_state:
                        lines.append(f"            self.transition_to({self.actor_name}State.{trans.to_state})")

                    # Handle guard failure
                    if trans.on_guard_fail:
                        lines.append("        else:")
                        # Process actions in on_guard_fail
                        for action in trans.on_guard_fail.actions:
                            lines.extend(["    " + l for l in self._generate_action_code_ast(action, indent_level=2, msg_var=None)])
                        if trans.on_guard_fail.target:
                            lines.append(f"            self.transition_to({self.actor_name}State.{trans.on_guard_fail.target})")
                else:
                    # No guard - just transition
                    if trans.to_state:
                        lines.append(f"        self.transition_to({self.actor_name}State.{trans.to_state})")
                break
        else:
            # No matching transition found - store params and transition
            for p in trigger.params:
                lines.append(f'        self.store("{p.name}", {p.name})')
            lines.append(f"        # Trigger processed - state machine will continue in tick()")

        return "\n".join(lines)

    def _generate_tick_method(self) -> str:
        """Generate the tick method with all state handling."""
        lines = ["    def tick(self, current_time: float) -> List[Message]:"]
        lines.append('        """Process one tick of the state machine."""')
        lines.append("        self.current_time = current_time")
        lines.append("        outgoing = []")
        lines.append("")

        # Group transitions by from-state
        transitions_by_state: Dict[str, List[Transition]] = {}
        for trans in self.actor.transitions:
            from_state = trans.from_state
            if from_state not in transitions_by_state:
                transitions_by_state[from_state] = []
            transitions_by_state[from_state].append(trans)

        first = True
        for state in self.actor.states:
            prefix = "if" if first else "elif"
            first = False

            lines.append(f"        {prefix} self.state == {self.actor_name}State.{state.name}:")

            state_transitions = transitions_by_state.get(state.name, [])
            if not state_transitions:
                # No transitions - passive state
                if state.description:
                    lines.append(f"            # {state.description}")
                lines.append("            pass")
            else:
                lines.extend(self._generate_state_body(state.name, state_transitions))

            lines.append("")

        lines.append("        return outgoing")
        return "\n".join(lines)

    def _generate_state_body(self, state_name: str, transitions: List[Transition]) -> List[str]:
        """Generate the body of a state handler."""
        lines = []

        # Build set of external trigger names
        external_trigger_names = {t.name for t in self.actor.triggers}

        # Separate transitions by trigger type
        auto_trans = [t for t in transitions if t.auto]
        msg_trans = [t for t in transitions if not t.auto
                     and t.trigger is not None
                     and not str(t.trigger).startswith("timeout(")
                     and t.trigger not in external_trigger_names]
        timeout_trans = [t for t in transitions if t.trigger and str(t.trigger).startswith("timeout(")]

        # Handle message triggers first (check queue)
        for trans in msg_trans:
            trigger = trans.trigger
            # Skip if it's an external trigger
            if trigger in external_trigger_names:
                continue

            msg_type = trigger
            lines.append(f"            # Check for {msg_type}")
            lines.append(f"            msgs = self.get_messages(MessageType.{msg_type})")
            lines.append("            if msgs:")
            lines.append("                msg = msgs[0]")
            lines.extend(self._generate_transition_code(trans, indent_level=4, msg_var="msg"))
            lines.append("                self.message_queue.remove(msg)  # Only remove processed message")
            lines.append("")

        # Handle timeout transitions
        for trans in timeout_trans:
            trigger = trans.trigger
            # Extract timeout parameter name: timeout(PARAM_NAME)
            if trigger.startswith("timeout(") and trigger.endswith(")"):
                param_name = trigger[8:-1]
                # Find a reasonable "started_at" key
                started_at_key = self._infer_started_at_key(state_name)
                lines.append(f"            # Timeout check")
                lines.append(f"            if current_time - self.load(\"{started_at_key}\", 0) > {param_name}:")
                lines.extend(self._generate_transition_code(trans, indent_level=4))
                lines.append("")

        # Handle auto transitions (immediate)
        # Track whether we've seen a guarded transition to use elif for subsequent ones
        first_guarded = True
        for trans in auto_trans:
            guard = trans.guard
            if guard:
                guard_code = self._generate_guard_check(guard)
                lines.append(f"            # Auto transition with guard: {guard}")
                # Use 'if' for first guarded transition, 'elif' for subsequent ones
                if_keyword = "if" if first_guarded else "elif"
                lines.append(f"            {if_keyword} {guard_code}:")
                lines.extend(self._generate_transition_code(trans, indent_level=4))
                first_guarded = False

                # Handle guard failure
                if trans.on_guard_fail:
                    lines.append("            else:")
                    # Process actions in on_guard_fail
                    for action in trans.on_guard_fail.actions:
                        lines.extend(["    " + l for l in self._generate_action_code_ast(action, indent_level=3, msg_var=None)])
                    if trans.on_guard_fail.target:
                        lines.append(f"                self.transition_to({self.actor_name}State.{trans.on_guard_fail.target})")
            else:
                lines.append("            # Auto transition")
                lines.extend(self._generate_transition_code(trans, indent_level=3))

        # If no transitions generated anything, add pass
        if not lines:
            lines.append("            pass")

        return lines

    def _generate_transition_code(self, trans: Transition, indent_level: int = 3, msg_var: str = None) -> List[str]:
        """Generate code for a transition's actions."""
        lines = []
        ind = "    " * indent_level

        for action in trans.actions:
            lines.extend(self._generate_action_code_ast(action, indent_level, msg_var))

        if trans.to_state:
            lines.append(f"{ind}self.transition_to({self.actor_name}State.{trans.to_state})")

        return lines

    def _generate_guard_check(self, guard_name: str) -> str:
        """Generate Python code for a guard check."""
        sanitized = sanitize_guard_name(guard_name)
        return f"self._check_{sanitized}()"

    def _infer_started_at_key(self, state_name: str) -> str:
        """Infer the 'started_at' key for timeout checking."""
        state_lower = state_name.lower()
        if "waiting" in state_lower:
            # Try to find what we're waiting for (check more specific patterns first)
            if "topup" in state_lower:
                return "topup_sent_at"
            elif "commitment" in state_lower:
                return "intent_sent_at"
            elif "result" in state_lower:
                return "requests_sent_at"
            elif "signature" in state_lower:
                return "propagated_at"
        return "state_entered_at"


def sanitize_guard_name(guard_name: str) -> str:
    """Convert an expression or guard name into a valid Python identifier."""
    import re
    # If it's already a valid identifier (named guard), use it directly
    if guard_name.isidentifier():
        return guard_name
    # Otherwise, create a sanitized version
    sanitized = guard_name
    sanitized = sanitized.replace("||", "_or_")
    sanitized = sanitized.replace("&&", "_and_")
    sanitized = sanitized.replace("==", "_eq_")
    sanitized = sanitized.replace("!=", "_neq_")
    sanitized = sanitized.replace(">=", "_gte_")
    sanitized = sanitized.replace("<=", "_lte_")
    sanitized = sanitized.replace(">", "_gt_")
    sanitized = sanitized.replace("<", "_lt_")
    sanitized = sanitized.replace(".", "_")
    sanitized = sanitized.replace("(", "_")
    sanitized = sanitized.replace(")", "_")
    sanitized = sanitized.replace(" ", "_")
    # Remove any remaining non-identifier chars
    sanitized = re.sub(r'[^a-zA-Z0-9_]', '', sanitized)
    # Remove consecutive underscores
    sanitized = re.sub(r'_+', '_', sanitized)
    # Remove leading/trailing underscores
    sanitized = sanitized.strip('_')
    # Truncate if too long
    if len(sanitized) > 60:
        sanitized = sanitized[:60]
    return sanitized


def _generate_function_statements(
    statements: List[FunctionStatement],
    lines: List[str],
    translator: 'ExpressionTranslator',
    local_vars: set,
    indent: int = 2
) -> None:
    """Generate Python code from function body statements.

    Args:
        statements: List of parsed statement AST nodes
        lines: Output list to append generated lines
        translator: ExpressionTranslator for DSL->Python conversion
        local_vars: Set of local variable names (function params + assigned vars)
        indent: Indentation level (number of 4-space units)
    """
    prefix = "    " * indent

    for stmt in statements:
        if isinstance(stmt, AssignmentStmt):
            # name = expression
            translated_expr = translator.translate(stmt.expression, local_vars=local_vars)
            lines.append(f"{prefix}{stmt.name} = {translated_expr}")
            # Add assigned variable to local vars for subsequent statements
            local_vars = local_vars | {stmt.name}

        elif isinstance(stmt, ReturnStmt):
            # return expression
            translated_expr = translator.translate(stmt.expression, local_vars=local_vars)
            lines.append(f"{prefix}return {translated_expr}")

        elif isinstance(stmt, ForStmt):
            # for var in iterable: body
            translated_iter = translator.translate(stmt.iterable, local_vars=local_vars)
            lines.append(f"{prefix}for {stmt.var_name} in {translated_iter}:")
            # Add loop variable to local vars for body
            body_local_vars = local_vars | {stmt.var_name}
            if stmt.body:
                _generate_function_statements(stmt.body, lines, translator, body_local_vars, indent + 1)
            else:
                lines.append(f"{prefix}    pass")

        elif isinstance(stmt, IfStmt):
            # if condition: then_body else: else_body
            translated_cond = translator.translate(stmt.condition, local_vars=local_vars)
            lines.append(f"{prefix}if {translated_cond}:")
            if stmt.then_body:
                _generate_function_statements(stmt.then_body, lines, translator, local_vars, indent + 1)
            else:
                lines.append(f"{prefix}    pass")
            if stmt.else_body:
                lines.append(f"{prefix}else:")
                _generate_function_statements(stmt.else_body, lines, translator, local_vars, indent + 1)


def generate_actor_helpers(actor: ActorDecl, schema: Schema) -> str:
    """Generate helper methods for an actor (payload builders, guards, etc.)."""
    lines = []
    actor_name = actor.name
    transitions = actor.transitions

    # Build lookup structures
    messages = {msg.name: msg for msg in schema.messages}
    blocks = {block.name: block for block in schema.blocks}

    # Create expression translator
    store_vars = {field.name for field in actor.store}
    parameters = {param.name for param in schema.parameters}
    enums = {enum.name: [v.name for v in enum.values] for enum in schema.enums}
    translator = ExpressionTranslator(store_vars, parameters, enums)

    # Collect all message types we need to build
    msg_types_to_build = set()
    for trans in transitions:
        for action in trans.actions:
            if isinstance(action, SendAction):
                if action.message:
                    msg_types_to_build.add(action.message)
            elif isinstance(action, BroadcastAction):
                if action.message:
                    msg_types_to_build.add(action.message)

    # Generate payload builder methods
    for msg_type in msg_types_to_build:
        msg_decl = messages.get(msg_type)
        lines.append(f"    def _build_{msg_type.lower()}_payload(self) -> Dict[str, Any]:")
        lines.append(f'        """Build payload for {msg_type} message."""')
        lines.append("        payload = {")

        if msg_decl:
            for field in msg_decl.fields:
                if field.name == "timestamp":
                    continue  # Skip timestamp - we add it explicitly
                if field.type == "object":
                    lines.append(f'            "{field.name}": self.load("{field.name}"),')
                else:
                    lines.append(f'            "{field.name}": self._serialize_value(self.load("{field.name}")),')

        lines.append("            \"timestamp\": self.current_time,")
        lines.append("        }")

        # Add signature if needed
        if msg_decl and msg_decl.signed:
            lines.append("        payload[\"signature\"] = sign(self.chain.private_key, hash_data(payload))")

        lines.append("        return payload")
        lines.append("")

    # Collect all guards - inline guard expressions from transitions
    all_guards = {}  # sanitized_name -> (description, expression)

    # Add inline guards from transitions
    for trans in transitions:
        guard = trans.guard
        if guard:
            # This is an inline guard expression
            sanitized = sanitize_guard_name(guard)
            if sanitized not in all_guards:
                all_guards[sanitized] = ("", guard)  # No description, expression is the guard itself

    # Generate guard methods
    for guard_name, (desc, expr) in all_guards.items():
        # Normalize and translate expression
        expr_oneline = " ".join(str(expr).split())
        translated = translator.translate(expr_oneline)

        lines.append(f"    def _check_{guard_name}(self) -> bool:")
        if desc:
            lines.append(f'        """{desc}"""')
        lines.append(f"        # Schema: {expr_oneline[:60]}...")
        lines.append(f"        return {translated}")
        lines.append("")

    # Generate compute methods - collect var_name -> from_expr mappings
    compute_exprs = {}  # var_name -> from_expression
    for trans in transitions:
        for action in trans.actions:
            if isinstance(action, ComputeAction):
                if action.name not in compute_exprs:
                    compute_exprs[action.name] = action.expression

    for var_name, from_expr in compute_exprs.items():
        lines.append(f"    def _compute_{var_name}(self) -> Any:")
        lines.append(f'        """Compute {var_name}."""')
        if from_expr:
            # Translate the expression
            translated = translator.translate(from_expr)
            lines.append(f"        # Schema: {from_expr[:60]}...")
            lines.append(f"        return {translated}")
        else:
            lines.append("        # No expression provided")
            lines.append("        return None")
        lines.append("")

    # Collect block types to build
    block_types_to_build = set()
    for trans in transitions:
        for action in trans.actions:
            if isinstance(action, AppendBlockAction):
                if action.block_type:
                    block_types_to_build.add(action.block_type)
            elif isinstance(action, AppendAction):
                # APPEND(my_chain, BLOCK_TYPE) is a chain append
                if action.list_name == "my_chain" and action.value:
                    block_types_to_build.add(action.value)

    # Generate block payload builders
    for block_type in block_types_to_build:
        block_decl = blocks.get(block_type)
        lines.append(f"    def _build_{block_type.lower()}_payload(self) -> Dict[str, Any]:")
        lines.append(f'        """Build payload for {block_type} chain block."""')
        lines.append("        return {")

        if block_decl:
            for field in block_decl.fields:
                if field.name == "timestamp":
                    lines.append(f'            "timestamp": self.current_time,')
                else:
                    lines.append(f'            "{field.name}": self.load("{field.name}"),')

        lines.append("        }")
        lines.append("")

    # Generate protocol function implementations (matching FORMAT.md primitives)
    # These are fully functional, not placeholders

    # _read_chain - READ(chain, query)
    lines.append("    def _read_chain(self, chain: Any, query: str) -> Any:")
    lines.append('        """READ: Read from a chain (own or cached peer chain)."""')
    lines.append("        if chain == 'my_chain' or chain is self.chain:")
    lines.append("            chain_obj = self.chain")
    lines.append("        elif isinstance(chain, str):")
    lines.append("            # It's a peer_id - look up in cached_chains")
    lines.append("            cached = self.load('cached_chains', {}).get(chain)")
    lines.append("            if cached:")
    lines.append("                # Return from cache based on query")
    lines.append("                if query == 'head' or query == 'head_hash':")
    lines.append("                    return cached.get('head_hash')")
    lines.append("                elif query == 'balance':")
    lines.append("                    return cached.get('balance', 0)")
    lines.append("                return cached.get(query)")
    lines.append("            # Fall back to chain's peer hash records")
    lines.append("            if query == 'head' or query == 'head_hash':")
    lines.append("                peer_block = self.chain.get_peer_hash(chain)")
    lines.append("                if peer_block:")
    lines.append("                    return peer_block.payload.get('hash')")
    lines.append("            return None")
    lines.append("        else:")
    lines.append("            chain_obj = chain")
    lines.append("        # Query the chain object")
    lines.append("        if query == 'head' or query == 'head_hash':")
    lines.append("            return chain_obj.head_hash if hasattr(chain_obj, 'head_hash') else None")
    lines.append("        elif query == 'balance':")
    lines.append("            return getattr(chain_obj, 'balance', 0)")
    lines.append("        elif hasattr(chain_obj, query):")
    lines.append("            return getattr(chain_obj, query)")
    lines.append("        elif hasattr(chain_obj, 'get_' + query):")
    lines.append("            return getattr(chain_obj, 'get_' + query)()")
    lines.append("        return None")
    lines.append("")

    # _chain_segment - CHAIN_SEGMENT(chain, hash)
    lines.append("    def _chain_segment(self, chain: Any, target_hash: str) -> List[dict]:")
    lines.append('        """CHAIN_SEGMENT: Extract chain segment up to target hash."""')
    lines.append("        if chain == 'my_chain' or chain is self.chain:")
    lines.append("            chain_obj = self.chain")
    lines.append("        elif hasattr(chain, 'to_segment'):")
    lines.append("            chain_obj = chain")
    lines.append("        else:")
    lines.append("            return []")
    lines.append("        if hasattr(chain_obj, 'to_segment'):")
    lines.append("            return chain_obj.to_segment(target_hash)")
    lines.append("        return []")
    lines.append("")

    # _verify_chain_segment
    lines.append("    def _verify_chain_segment(self, segment: List[dict]) -> bool:")
    lines.append('        """VERIFY_CHAIN_SEGMENT: Verify a chain segment is valid."""')
    lines.append("        if not segment:")
    lines.append("            return False")
    lines.append("        # Verify hash chain integrity")
    lines.append("        for i in range(1, len(segment)):")
    lines.append('            if segment[i].get("previous_hash") != segment[i-1].get("block_hash"):')
    lines.append("                return False")
    lines.append("            # Verify sequences are consecutive")
    lines.append('            if segment[i].get("sequence") != segment[i-1].get("sequence") + 1:')
    lines.append("                return False")
    lines.append("        return True")
    lines.append("")

    # _chain_contains_hash
    lines.append("    def _chain_contains_hash(self, chain_or_segment: Any, target_hash: str) -> bool:")
    lines.append('        """CHAIN_CONTAINS_HASH: Check if chain/segment contains a hash."""')
    lines.append("        if isinstance(chain_or_segment, list):")
    lines.append("            # It's a segment (list of block dicts)")
    lines.append("            return any(b.get('block_hash') == target_hash for b in chain_or_segment)")
    lines.append("        elif hasattr(chain_or_segment, 'contains_hash'):")
    lines.append("            # It's a Chain object")
    lines.append("            return chain_or_segment.contains_hash(target_hash)")
    lines.append("        return False")
    lines.append("")

    # _chain_state_at
    lines.append("    def _chain_state_at(self, chain_or_segment: Any, target_hash: str) -> Optional[Dict[str, Any]]:")
    lines.append('        """CHAIN_STATE_AT: Extract chain state at a specific block hash."""')
    lines.append("        if isinstance(chain_or_segment, list):")
    lines.append("            # It's a segment - delegate to Chain.state_from_segment")
    lines.append("            return Chain.state_from_segment(chain_or_segment, target_hash)")
    lines.append("        elif hasattr(chain_or_segment, 'get_state_at'):")
    lines.append("            # It's a Chain object")
    lines.append("            return chain_or_segment.get_state_at(target_hash)")
    lines.append("        return None")
    lines.append("")

    # _seeded_rng
    lines.append("    def _seeded_rng(self, seed: bytes) -> Any:")
    lines.append('        """SEEDED_RNG: Create a seeded random number generator."""')
    lines.append("        import random as _random")
    lines.append("        return _random.Random(seed)")
    lines.append("")

    # _seeded_sample
    lines.append("    def _seeded_sample(self, rng: Any, lst: list, n: int) -> list:")
    lines.append('        """SEEDED_SAMPLE: Deterministically sample n items from list."""')
    lines.append("        if not lst:")
    lines.append("            return []")
    lines.append("        return rng.sample(lst, min(n, len(lst)))")
    lines.append("")

    # _sort
    lines.append("    def _sort(self, lst: list, key_fn: str = None) -> list:")
    lines.append('        """SORT: Sort list by key."""')
    lines.append("        return sorted(lst) if lst else []")
    lines.append("")

    # _abort
    lines.append("    def _abort(self, reason: str) -> None:")
    lines.append('        """ABORT: Exit state machine with error."""')
    lines.append('        raise RuntimeError(f"ABORT: {reason}")')
    lines.append("")

    # _concat
    lines.append("    def _concat(self, a: list, b: list) -> list:")
    lines.append('        """CONCAT: Concatenate two lists."""')
    lines.append("        return (a or []) + (b or [])")
    lines.append("")

    # _has_key
    lines.append("    def _has_key(self, d: dict, key: Any) -> bool:")
    lines.append('        """HAS_KEY: Check if dict contains key (null-safe)."""')
    lines.append("        if d is None:")
    lines.append("            return False")
    lines.append("        return key in d if isinstance(d, dict) else False")
    lines.append("")

    # Generate methods from functions section
    for func in schema.functions:
        params = func.params
        returns = func.return_type or "Any"
        body = func.body or ""

        # Build parameter list
        param_strs = ["self"]
        for param in params:
            py_type = python_type(param.type)
            param_strs.append(f"{param.name}: {py_type}")

        # Map return type using python_type
        py_returns = python_type(returns)

        lines.append(f"    def _{func.name}({', '.join(param_strs)}) -> {py_returns}:")
        lines.append(f'        """Compute {func.name}."""')

        # Handle native functions - call imported library function
        if func.is_native:
            arg_names = [p.name for p in params]
            # The import is added at the top of the file; here we just call it
            lines.append(f'        # Native function from: {func.library_path}')
            lines.append(f'        return {func.name}({", ".join(arg_names)})')
            lines.append("")
            continue

        # Create translator with function parameters as local variables (not store vars)
        # Include schema parameters and enums for proper translation
        param_names = {p.name for p in params}
        schema_params = {p.name for p in schema.parameters}
        schema_enums = {enum.name: [v.name for v in enum.values] for enum in schema.enums}
        func_translator = ExpressionTranslator(
            store_vars=set(),  # Function params are local, not store vars
            parameters=schema_params,
            enums=schema_enums
        )

        # Generate body from parsed statements
        if func.statements:
            # Use parsed statement AST
            _generate_function_statements(func.statements, lines, func_translator, param_names, indent=2)
        else:
            # Fallback to raw body parsing for backwards compatibility
            body_stripped = body.strip() if body else ""
            body_normalized = ' '.join(body_stripped.split())

            if body_normalized.upper().startswith("RETURN "):
                expr = body_normalized[7:].strip()
                translated = func_translator.translate(expr, local_vars=param_names)
                lines.append(f"        return {translated}")
            elif "# In simulation" in body_stripped:
                if returns == "bool":
                    lines.append("        return True")
                else:
                    lines.append("        return None")
            else:
                body_oneline = " ".join(body_stripped.split())[:50]
                lines.append(f"        # TODO: Implement - {body_oneline}...")
                lines.append("        return None")
        lines.append("")

    return "\n".join(lines)


def generate_python(tx_dir: Path, output_path: Path = None) -> str:
    """Generate Python code from transaction definition."""
    schema = load_transaction(tx_dir)

    tx_name = schema.transaction.name if schema.transaction else "Unknown"
    tx_id = schema.transaction.id if schema.transaction else "00"
    tx_desc = schema.transaction.description if schema.transaction else ""

    lines = ['"""']
    lines.append(f"Transaction {tx_id}: {tx_name}")
    lines.append("")
    lines.append(f"{tx_desc}")
    lines.append("")
    lines.append("GENERATED FROM transaction.omt")
    lines.append('"""')
    lines.append("")
    lines.append("from enum import Enum, auto")
    lines.append("from dataclasses import dataclass, field")
    lines.append("from typing import Dict, List, Optional, Tuple, Any")
    lines.append("")
    lines.append("from ..chain.primitives import (")
    lines.append("    Chain, Block, BlockType,")
    lines.append("    hash_data, sign, verify_sig, generate_id, random_bytes")
    lines.append(")")
    lines.append("")

    # Import native functions
    native_funcs = [f for f in schema.functions if f.is_native]
    if native_funcs:
        # Group by library path
        by_library: Dict[str, List[str]] = {}
        for func in native_funcs:
            lib = func.library_path
            if lib not in by_library:
                by_library[lib] = []
            by_library[lib].append(func.name)

        for lib_path, func_names in sorted(by_library.items()):
            # Use simulations.native as the mock library location
            mock_path = "simulations.native." + lib_path.split(".")[-1]
            lines.append(f"try:")
            lines.append(f"    from {lib_path} import {', '.join(sorted(func_names))}")
            lines.append(f"except ImportError:")
            lines.append(f"    from {mock_path} import {', '.join(sorted(func_names))}")
        lines.append("")

    lines.append("")

    # Parameters
    lines.append(generate_parameters_python(schema))

    # Enums
    lines.append(generate_enums_python(schema))

    # Messages
    lines.append(generate_messages_python(schema))

    # Base Actor class
    lines.append("# =============================================================================")
    lines.append("# Actor Base Class")
    lines.append("# =============================================================================")
    lines.append("")
    lines.append("@dataclass")
    lines.append("class Actor:")
    lines.append('    """Base class for state machine actors."""')
    lines.append("    peer_id: str")
    lines.append("    chain: Chain")
    lines.append("    current_time: float = 0.0")
    lines.append("")
    lines.append("    local_store: Dict[str, Any] = field(default_factory=dict)")
    lines.append("    message_queue: List[Message] = field(default_factory=list)")
    lines.append("    state_history: List[Tuple[float, Any]] = field(default_factory=list)")
    lines.append("")
    lines.append("    def store(self, key: str, value: Any):")
    lines.append("        self.local_store[key] = value")
    lines.append("")
    lines.append("    def load(self, key: str, default: Any = None) -> Any:")
    lines.append("        return self.local_store.get(key, default)")
    lines.append("")
    lines.append("    def receive_message(self, msg: Message):")
    lines.append("        self.message_queue.append(msg)")
    lines.append("")
    lines.append("    @staticmethod")
    lines.append("    def _to_hashable(*args) -> dict:")
    lines.append('        """Convert arguments to a hashable dict."""')
    lines.append("        result = {}")
    lines.append("        for i, arg in enumerate(args):")
    lines.append("            if isinstance(arg, bytes):")
    lines.append("                result[f'_{i}'] = arg.hex()")
    lines.append("            else:")
    lines.append("                result[f'_{i}'] = arg")
    lines.append("        return result")
    lines.append("")
    lines.append("    @staticmethod")
    lines.append("    def _serialize_value(val: Any) -> Any:")
    lines.append('        """Convert value to JSON-serializable form."""')
    lines.append("        if isinstance(val, bytes):")
    lines.append("            return val.hex()")
    lines.append("        if isinstance(val, Enum):")
    lines.append("            return val.name")
    lines.append("        return val")
    lines.append("")
    lines.append("    def get_messages(self, msg_type: MessageType = None) -> List[Message]:")
    lines.append("        if msg_type is None:")
    lines.append("            return self.message_queue")
    lines.append("        return [m for m in self.message_queue if m.msg_type == msg_type]")
    lines.append("")
    lines.append("    def clear_messages(self, msg_type: MessageType = None):")
    lines.append("        if msg_type is None:")
    lines.append("            self.message_queue = []")
    lines.append("        else:")
    lines.append("            self.message_queue = [m for m in self.message_queue if m.msg_type != msg_type]")
    lines.append("")
    lines.append("    def transition_to(self, new_state):")
    lines.append("        self.state = new_state")
    lines.append("        self.state_history.append((self.current_time, new_state))")
    lines.append("        self.store('state_entered_at', self.current_time)")
    lines.append("")
    lines.append("    def in_state(self, state_name: str) -> bool:")
    lines.append('        """Check if actor is in a named state."""')
    lines.append("        return self.state.name == state_name")
    lines.append("")
    lines.append("    def tick(self, current_time: float) -> List[Message]:")
    lines.append("        raise NotImplementedError")
    lines.append("")
    lines.append("")

    # Actor classes
    for actor in schema.actors:
        lines.append("# =============================================================================")
        lines.append(f"# {actor.name}")
        lines.append("# =============================================================================")
        lines.append("")

        generator = PythonActorGenerator(actor, schema)
        lines.append(generator.generate())
        lines.append("")
        lines.append(generate_actor_helpers(actor, schema))

    result = "\n".join(lines)

    if output_path:
        with open(output_path, "w") as f:
            f.write(result)
        print(f"Generated: {output_path}")

    return result


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Generate documentation and Python code from transaction definitions"
    )
    parser.add_argument("tx_dir", help="Directory containing transaction.omt")
    parser.add_argument("--markdown", action="store_true", help="Generate markdown documentation")
    parser.add_argument("--python", action="store_true", help="Generate Python code")
    parser.add_argument("--output-dir", help="Output directory")

    args = parser.parse_args()

    tx_dir = Path(args.tx_dir)
    if not tx_dir.exists():
        print(f"Error: Directory not found: {tx_dir}", file=sys.stderr)
        sys.exit(1)

    if args.markdown:
        output_dir = Path(args.output_dir) if args.output_dir else tx_dir.parent
        tx_name = tx_dir.name
        output_path = output_dir / f"{tx_name}.md"
        generate_markdown(tx_dir, output_path)

    if args.python:
        output_dir = Path(args.output_dir) if args.output_dir else Path("simulations/transactions")
        tx_name = tx_dir.name.split("_", 1)[1] if "_" in tx_dir.name else tx_dir.name
        output_path = output_dir / f"{tx_name}_generated.py"
        generate_python(tx_dir, output_path)

    if not args.markdown and not args.python:
        print("Specify --markdown and/or --python to generate output")
        sys.exit(1)


if __name__ == "__main__":
    main()
