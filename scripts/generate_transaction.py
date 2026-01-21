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

from dsl_peg_parser import load_transaction_ast
from dsl_ast import (
    Schema, Transaction, Parameter, EnumDecl, MessageDecl, BlockDecl,
    ActorDecl, TriggerDecl, StateDecl, Transition, FunctionDecl,
    StoreAction, ComputeAction, LookupAction, SendAction, BroadcastAction, AppendAction, AppendBlockAction,
    Field, OnGuardFail,
    AssignmentStmt, ReturnStmt, ForStmt, IfStmt, FunctionStatement
)


# =============================================================================
# AST VALIDATION - Ensure we're using AST nodes, not string manipulation
# =============================================================================

# Forbidden patterns in expression handling code.
# If any of these patterns are found in the generator (outside of allowed contexts),
# the module will refuse to load. This prevents string-based expression handling
# from being accidentally added.
_FORBIDDEN_PATTERNS = [
    # Regex on expressions
    (r're\.search\([^)]*expr', "Don't use regex to parse expressions - use AST nodes"),
    (r're\.match\([^)]*expr', "Don't use regex to parse expressions - use AST nodes"),
    (r're\.findall\([^)]*expr', "Don't use regex to parse expressions - use AST nodes"),
    (r're\.sub\([^)]*expr', "Don't use regex to transform expressions - use AST nodes"),
    # String splitting on expressions
    (r'expr[^=]*\.split\(', "Don't split expression strings - use AST nodes"),
    # String contains checks for operators (outside of validation code)
    (r'if ["\'][\+\-\*/].*in.*expr', "Don't check for operators in expression strings - use AST nodes"),
]

# Allowed contexts where string processing is OK (line number ranges or function names)
_ALLOWED_CONTEXTS = [
    'assert_is_ast_node',  # Validation function can check strings
    'sanitize_guard_name',  # Converting guard names to identifiers is OK
    'expr_to_python',  # The expr_to_python function itself
    '_translate_literal',  # String literal escaping is OK
    '# Schema:',  # Comments are OK
    'for_comment',  # Formatting for comments is OK
]


def _validate_no_string_expression_handling():
    """Scan this module's source for forbidden string-processing patterns.

    This runs at module load time to catch accidental string-based expression handling.
    """
    import inspect
    source_file = inspect.getfile(inspect.currentframe())

    try:
        with open(source_file, 'r') as f:
            lines = f.readlines()
    except (IOError, OSError):
        return  # Can't read source, skip validation

    for line_num, line in enumerate(lines, 1):
        # Skip allowed contexts
        if any(ctx in line for ctx in _ALLOWED_CONTEXTS):
            continue

        # Check forbidden patterns
        for pattern, message in _FORBIDDEN_PATTERNS:
            if re.search(pattern, line, re.IGNORECASE):
                raise RuntimeError(
                    f"Forbidden string-processing pattern detected at line {line_num}:\n"
                    f"  {line.strip()}\n"
                    f"  {message}\n"
                    f"  Pattern: {pattern}"
                )


def assert_is_ast_node(value, context: str = ""):
    """Assert that a value is an AST node, not a string expression.

    This guard prevents string-based expression handling from creeping back in.
    Use this when receiving expression values that should be AST nodes.
    """
    if isinstance(value, str):
        # Allow None-ish values
        if not value or value in ('None', 'null', 'true', 'false'):
            return
        # Reject strings that look like expressions (contain operators, parens, dots)
        suspicious_patterns = [' + ', ' - ', ' * ', ' / ', ' == ', ' != ', ' >= ', ' <= ',
                              ' > ', ' < ', ' and ', ' or ', '(', ')', '.']
        for pattern in suspicious_patterns:
            if pattern in value:
                raise ValueError(
                    f"String expression found where AST node expected{' in ' + context if context else ''}: {value!r}. "
                    "Use proper AST nodes instead of string manipulation."
                )


# Run validation at module load time
_validate_no_string_expression_handling()


# =============================================================================
# AST TRANSLATOR - Direct AST to Python translation
# =============================================================================

class ASTTranslator:
    """Translate DSL AST nodes directly to Python code."""

    # Built-in actor properties (accessed as self.X)
    ACTOR_PROPS = {'peer_id', 'chain', 'state', 'cached_chains'}

    # DSL function -> Python function mapping
    FUNC_MAP = {
        # Cryptographic
        'HASH': 'hash_data',
        'VERIFY_SIG': 'verify_sig',
        'MULTI_SIGN': 'multi_sign',
        'RANDOM_BYTES': 'random_bytes',
        'GENERATE_ID': 'generate_id',
        # Compute
        'LENGTH': 'len',
        'CONCAT': 'self._concat',
        'SORT': 'self._sort',
        'HAS_KEY': 'self._has_key',
        'ABS': 'abs',
        'MIN': 'min',
        'MAX': 'max',
        # Lowercase aliases
        'hash': 'hash_data',
        'verify_sig': 'verify_sig',
        'random_bytes': 'random_bytes',
        'len': 'len',
    }

    # Functions that need special expansion
    SPECIAL_FUNCS = {
        'SIGN': lambda args: f'sign(self.chain.private_key, hash_data({args}))',
        'NOW': lambda args: 'self.current_time',
    }

    # Functions that become self._method calls
    SELF_METHODS = {
        'CHAIN_CONTAINS_HASH': '_chain_contains_hash',
        'CHAIN_STATE_AT': '_chain_state_at',
        'CHAIN_SEGMENT': '_chain_segment',
        'VERIFY_CHAIN_SEGMENT': '_verify_chain_segment',
        'SEEDED_RNG': '_seeded_rng',
        'SEEDED_SAMPLE': '_seeded_sample',
        'READ': '_read_chain',
        'GET': '_GET',
        'CONTAINS': '_CONTAINS',
        'REMOVE': '_REMOVE',
        'SET_EQUALS': '_SET_EQUALS',
        'EXTRACT_FIELD': '_EXTRACT_FIELD',
        'COUNT_MATCHING': '_COUNT_MATCHING',
        'SELECT_WITNESSES': '_SELECT_WITNESSES',
        'VERIFY_WITNESS_SELECTION': '_VERIFY_WITNESS_SELECTION',
        'VALIDATE_LOCK_RESULT': '_VALIDATE_LOCK_RESULT',
        'VALIDATE_TOPUP_RESULT': '_VALIDATE_TOPUP_RESULT',
    }

    # Functions where first arg is a literal key (not translated)
    LITERAL_KEY_FUNCS = {'LOAD': 'self.load("{}")'}

    def __init__(self, store_vars: Set[str] = None, enum_names: Set[str] = None,
                 enum_values: Dict[str, str] = None, parameters: Set[str] = None):
        self.store_vars = store_vars or set()
        self.enum_names = enum_names or set()
        self.enum_values = enum_values or {}  # value_name -> enum_type
        self.parameters = parameters or set()
        self._local_vars: Set[str] = set()
        self._msg_var: str = None  # Set to message variable name when in message context

    def translate(self, expr, local_vars: Set[str] = None) -> str:
        """Translate an AST expression node to Python code.

        Args:
            expr: AST node or string (for backwards compatibility)
            local_vars: Set of local variable names (e.g., lambda params)
        """
        if local_vars:
            old_locals = self._local_vars
            self._local_vars = self._local_vars | local_vars
            result = self._translate_node(expr)
            self._local_vars = old_locals
            return result
        return self._translate_node(expr)

    def _translate_node(self, expr) -> str:
        """Recursively translate an AST node to Python."""
        if expr is None:
            return "None"

        # Guard against string-based expression handling creeping back in
        if isinstance(expr, str):
            # Allow simple identifiers and quoted string literals
            if expr.isidentifier() or (expr.startswith('"') and expr.endswith('"')):
                pass  # OK - simple identifier or string literal
            else:
                raise ValueError(
                    f"String expression passed to AST translator: {expr!r}. "
                    "Use proper AST nodes instead of strings. "
                    "If this is intentional, update the translator to handle this case."
                )
        if isinstance(expr, str):
            # Legacy string - just return it (already Python or identifier)
            return self._translate_identifier(expr)

        type_class = type(expr).__name__

        if type_class == 'Identifier':
            return self._translate_identifier(expr.name)

        elif type_class == 'Literal':
            return self._translate_literal(expr)

        elif type_class == 'BinaryExpr':
            left = self._translate_node(expr.left)
            right = self._translate_node(expr.right)
            op_map = {
                'ADD': '+', 'SUB': '-', 'MUL': '*', 'DIV': '/',
                'EQ': '==', 'NEQ': '!=', 'LT': '<', 'GT': '>',
                'LTE': '<=', 'GTE': '>=', 'AND': 'and', 'OR': 'or'
            }
            op = op_map.get(expr.op.name, str(expr.op.name))
            return f"({left} {op} {right})"

        elif type_class == 'UnaryExpr':
            operand = self._translate_node(expr.operand)
            if expr.op.name == 'NOT':
                return f"(not {operand})"
            elif expr.op.name == 'NEG':
                return f"(-{operand})"
            return operand

        elif type_class == 'IfExpr':
            cond = self._translate_node(expr.condition)
            then_e = self._translate_node(expr.then_expr)
            else_e = self._translate_node(expr.else_expr)
            return f"({then_e} if {cond} else {else_e})"

        elif type_class == 'FunctionCallExpr':
            return self._translate_function_call(expr)

        elif type_class == 'FieldAccessExpr':
            return self._translate_field_access(expr)

        elif type_class == 'DynamicFieldAccessExpr':
            obj = self._translate_node(expr.object)
            key = self._translate_node(expr.key_expr)
            return f"{obj}.get({key})"

        elif type_class == 'IndexAccessExpr':
            obj = self._translate_node(expr.object)
            index = self._translate_node(expr.index)
            return f"{obj}[{index}]"

        elif type_class == 'LambdaExpr':
            # Lambdas are handled specially by FILTER/MAP
            # If we get here standalone, convert to Python lambda
            old_locals = self._local_vars
            self._local_vars = self._local_vars | {expr.param}
            body = self._translate_node(expr.body)
            self._local_vars = old_locals
            return f"lambda {expr.param}: {body}"

        elif type_class == 'StructLiteralExpr':
            return self._translate_struct_literal(expr)

        elif type_class == 'ListLiteralExpr':
            elements = [self._translate_node(e) for e in expr.elements]
            return "[" + ", ".join(elements) + "]"

        elif type_class == 'EnumRefExpr':
            # Check if this is actually an enum reference or a field access
            # Parser creates EnumRefExpr for any X.Y pattern, but if X isn't a known enum,
            # it's really a field access
            if expr.enum_name in self.enum_names:
                return f"{expr.enum_name}.{expr.value}"
            else:
                # Treat as field access: X.Y where X is a variable
                obj_name = expr.enum_name
                field = expr.value
                # Translate the object identifier
                obj = self._translate_identifier(obj_name)
                # Check for actor properties (self.X) - use direct attribute access
                if obj_name in self.ACTOR_PROPS:
                    return f'{obj}.{field}'
                # For store loads, use .get()
                if obj.startswith('self.load('):
                    return f'{obj}.get("{field}")'
                # For local variables (function params), use .get() since they're often dicts
                if obj_name in self._local_vars:
                    return f'{obj}.get("{field}")'
                # Default: direct attribute access
                return f'{obj}.{field}'

        else:
            # Fallback
            return str(expr)

    def _translate_identifier(self, name: str) -> str:
        """Translate an identifier based on context."""
        # Check if this is already a string literal (from expr_to_python)
        if (name.startswith('"') and name.endswith('"')) or \
           (name.startswith("'") and name.endswith("'")):
            return name  # Already a string literal

        # Check for reserved keywords
        if name == 'null':
            return 'None'
        if name == 'true':
            return 'True'
        if name == 'false':
            return 'False'

        # Check for 'message' in message-handling context
        if name == 'message' and self._msg_var:
            return self._msg_var

        # Check local variables (lambda params, function params)
        if name in self._local_vars:
            return name

        # Check actor properties
        if name in self.ACTOR_PROPS:
            return f'self.{name}'

        # Check parameters (constants)
        if name in self.parameters:
            return name  # Keep as uppercase constant

        # Check enum values
        if name in self.enum_values:
            enum_type = self.enum_values[name]
            return f'{enum_type}.{name}'

        # Check store variables
        if name in self.store_vars:
            return f'self.load("{name}")'

        # Unknown lowercase identifier - treat as string literal
        # This handles cases like STORE(verdict, accept) where 'accept' is a string value
        if name.islower() and name.isalpha():
            return f'"{name}"'

        # Unknown - assume it's a store variable or external reference
        return f'self.load("{name}")'

    def _translate_literal(self, expr) -> str:
        """Translate a literal value."""
        if expr.type == 'string':
            # Escape quotes in string
            escaped = expr.value.replace('\\', '\\\\').replace('"', '\\"')
            return f'"{escaped}"'
        elif expr.type == 'bool':
            return 'True' if expr.value else 'False'
        elif expr.type == 'null':
            return 'None'
        else:
            return str(expr.value)

    def _translate_function_call(self, expr) -> str:
        """Translate a function call."""
        name = expr.name
        args = expr.args

        # Handle FILTER and MAP specially - convert to list comprehensions
        if name == 'FILTER' and len(args) == 2:
            list_expr = self._translate_node(args[0])
            lambda_arg = args[1]
            if type(lambda_arg).__name__ == 'LambdaExpr':
                var = lambda_arg.param
                old_locals = self._local_vars
                self._local_vars = self._local_vars | {var}
                cond = self._translate_node(lambda_arg.body)
                self._local_vars = old_locals
                return f"[{var} for {var} in {list_expr} if {cond}]"

        if name == 'MAP' and len(args) == 2:
            list_expr = self._translate_node(args[0])
            lambda_arg = args[1]
            if type(lambda_arg).__name__ == 'LambdaExpr':
                var = lambda_arg.param
                old_locals = self._local_vars
                self._local_vars = self._local_vars | {var}
                transform = self._translate_node(lambda_arg.body)
                self._local_vars = old_locals
                return f"[{transform} for {var} in {list_expr}]"

        # Handle special functions
        if name in self.SPECIAL_FUNCS:
            translated_args = ", ".join(self._translate_node(a) for a in args)
            return self.SPECIAL_FUNCS[name](translated_args)

        # Handle LOAD specially - first arg is literal key
        if name == 'LOAD':
            if args:
                key_arg = args[0]
                # Extract key name from identifier
                if type(key_arg).__name__ == 'Identifier':
                    key = key_arg.name
                elif isinstance(key_arg, str):
                    key = key_arg
                else:
                    key = self._translate_node(key_arg)
                    # Strip quotes if it's a string literal
                    if key.startswith('"') and key.endswith('"'):
                        key = key[1:-1]
                return f'self.load("{key}")'
            return 'self.load("")'

        # Handle HASH - needs _to_hashable wrapper for multiple values
        if name == 'HASH':
            # Flatten ADD expressions: HASH(a + b + c) -> HASH(_to_hashable((a, b, c)))
            if len(args) == 1 and type(args[0]).__name__ == 'BinaryExpr':
                flattened = self._flatten_add_expr(args[0])
                if len(flattened) > 1:
                    translated_parts = [self._translate_node(p) for p in flattened]
                    return f'hash_data(self._to_hashable(({", ".join(translated_parts)})))'
            # Multiple args: HASH(a, b, c) -> HASH(_to_hashable((a, b, c)))
            if len(args) > 1:
                translated_args = ", ".join(self._translate_node(a) for a in args)
                return f'hash_data(self._to_hashable(({translated_args})))'

        # Handle self._ method calls
        if name in self.SELF_METHODS:
            method = self.SELF_METHODS[name]
            translated_args = ", ".join(self._translate_node(a) for a in args)
            return f'self.{method}({translated_args})'

        # Handle built-in function mapping
        if name in self.FUNC_MAP:
            py_func = self.FUNC_MAP[name]
            translated_args = ", ".join(self._translate_node(a) for a in args)
            return f'{py_func}({translated_args})'

        # Unknown function - assume it's a self._ method (schema-defined)
        translated_args = ", ".join(self._translate_node(a) for a in args)
        return f'self._{name}({translated_args})'

    def _translate_field_access(self, expr) -> str:
        """Translate field access (obj.field)."""
        obj_node = expr.object
        field = expr.field

        # Handle 'message' keyword specially
        if type(obj_node).__name__ == 'Identifier' and obj_node.name == 'message':
            if field == 'sender':
                return '_msg.sender'
            elif field == 'payload':
                return '_msg.payload'
            else:
                return f'_msg.payload.get("{field}")'

        # Translate the object
        obj = self._translate_node(obj_node)

        # Check if this is accessing an enum
        if type(obj_node).__name__ == 'Identifier' and obj_node.name in self.enum_names:
            return f'{obj_node.name}.{field}'

        # Check for actor properties (self.X) - use direct attribute access
        if type(obj_node).__name__ == 'Identifier' and obj_node.name in self.ACTOR_PROPS:
            return f'{obj}.{field}'

        # Check for nested access on result of function/dict
        # If obj ends with ) or ], it's a function call result or index - use .get()
        if obj.endswith(')') or obj.endswith(']'):
            return f'{obj}.get("{field}")'

        # For store variables, use .get() for nested access
        if obj.startswith('self.load('):
            return f'{obj}.get("{field}")'

        # For message payload access, use .get()
        if obj == '_msg.payload':
            return f'{obj}.get("{field}")'

        # For local variables (function params), use .get() since they're often dicts
        if type(obj_node).__name__ == 'Identifier' and obj_node.name in self._local_vars:
            return f'{obj}.get("{field}")'

        # Default: direct attribute access (for self.X properties, etc.)
        return f'{obj}.{field}'

    def _translate_struct_literal(self, expr) -> str:
        """Translate struct literal to Python dict."""
        parts = []

        # Handle spread
        if expr.spread:
            spread = self._translate_node(expr.spread)
            parts.append(f'**{spread}')

        # Handle fields
        for key, val in expr.fields.items():
            translated_val = self._translate_node(val)
            parts.append(f'"{key}": {translated_val}')

        return '{' + ', '.join(parts) + '}'

    def get_enum_reference(self, value_name: str) -> Optional[str]:
        """Get full enum reference for a value name."""
        if value_name in self.enum_values:
            enum_type = self.enum_values[value_name]
            return f'{enum_type}.{value_name}'
        return None

    def _flatten_add_expr(self, expr) -> list:
        """Flatten nested ADD binary expressions into a list of operands.

        Used for HASH(a + b + c) -> HASH(_to_hashable((a, b, c)))
        """
        result = []
        type_name = type(expr).__name__

        if type_name == 'BinaryExpr' and hasattr(expr.op, 'name') and expr.op.name == 'ADD':
            # Recursively flatten left and right
            result.extend(self._flatten_add_expr(expr.left))
            result.extend(self._flatten_add_expr(expr.right))
        else:
            # Not an ADD expression, just return as single item
            result.append(expr)

        return result


def load_transaction(tx_dir: Path) -> Schema:
    """Load transaction definition from directory (DSL .omt file)."""
    from dsl_validate import validate_and_report

    dsl_path = tx_dir / "transaction.omt"
    if dsl_path.exists():
        schema = load_transaction_ast(dsl_path)
        # Run semantic validation (raises on errors, warns on warnings)
        result = validate_and_report(schema, raise_on_error=True)
        if result.has_warnings:
            import sys
            for warning in result.warnings:
                print(f"Warning: {warning}", file=sys.stderr)
        return schema

    raise FileNotFoundError(f"Transaction not found: tried {dsl_path}")


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

def format_type_for_md(type_expr) -> str:
    """Format a TypeExpr AST node as a human-readable string for markdown."""
    if type_expr is None:
        return "any"
    if isinstance(type_expr, str):
        return type_expr

    type_class = type(type_expr).__name__

    if type_class == 'SimpleType':
        return type_expr.name
    elif type_class == 'ListType':
        inner = format_type_for_md(type_expr.element_type)
        return f"list<{inner}>"
    elif type_class == 'MapType':
        key = format_type_for_md(type_expr.key_type)
        val = format_type_for_md(type_expr.value_type)
        return f"map<{key}, {val}>"
    else:
        return str(type_expr)


def format_trigger_for_md(trigger) -> str:
    """Format a trigger AST node as a human-readable string for markdown."""
    if trigger is None:
        return "?"
    if isinstance(trigger, str):
        return trigger

    type_class = type(trigger).__name__

    if type_class == 'MessageTrigger':
        return trigger.message_type
    elif type_class == 'TimeoutTrigger':
        return f"timeout({trigger.parameter})"
    elif type_class == 'NamedTrigger':
        return trigger.name
    else:
        return str(trigger)


def format_expr_for_md(expr) -> str:
    """Format an expression AST node as a human-readable string for markdown."""
    if expr is None:
        return ""
    if isinstance(expr, str):
        return expr

    type_class = type(expr).__name__

    if type_class == 'Identifier':
        return expr.name
    elif type_class == 'Literal':
        if expr.type == 'string':
            return f'"{expr.value}"'
        elif expr.type == 'null':
            return "null"
        elif expr.type == 'bool':
            return "true" if expr.value else "false"
        return str(expr.value)
    elif type_class == 'BinaryExpr':
        left = format_expr_for_md(expr.left)
        right = format_expr_for_md(expr.right)
        op_map = {
            'ADD': '+', 'SUB': '-', 'MUL': '*', 'DIV': '/',
            'EQ': '==', 'NEQ': '!=', 'LT': '<', 'GT': '>',
            'LTE': '<=', 'GTE': '>=', 'AND': 'and', 'OR': 'or'
        }
        op = op_map.get(expr.op.name, str(expr.op.name))
        return f"{left} {op} {right}"
    elif type_class == 'UnaryExpr':
        operand = format_expr_for_md(expr.operand)
        if expr.op.name == 'NOT':
            return f"NOT {operand}"
        elif expr.op.name == 'NEG':
            return f"-{operand}"
        return operand
    elif type_class == 'FunctionCallExpr':
        args = ", ".join(format_expr_for_md(a) for a in expr.args)
        return f"{expr.name}({args})"
    elif type_class == 'FieldAccessExpr':
        obj = format_expr_for_md(expr.object)
        return f"{obj}.{expr.field}"
    elif type_class == 'IndexAccessExpr':
        obj = format_expr_for_md(expr.object)
        index = format_expr_for_md(expr.index)
        return f"{obj}[{index}]"
    elif type_class == 'EnumRefExpr':
        return f"{expr.enum_name}.{expr.value}"
    elif type_class == 'LambdaExpr':
        body = format_expr_for_md(expr.body)
        return f"{expr.param} => {body}"
    else:
        return str(expr)


def extract_omt_sections(omt_path: Path) -> Dict[str, str]:
    """Extract named sections from an .omt file.

    Sections are delimited by lines like:
    # =============================================================================
    # SECTION_NAME
    # =============================================================================

    Returns a dict mapping section name -> section content (without the header).
    """
    with open(omt_path) as f:
        content = f.read()

    sections = {}
    lines = content.split('\n')

    current_section = None
    section_lines = []
    in_header = False

    i = 0
    while i < len(lines):
        line = lines[i]

        # Check for section header start
        if line.startswith('# ====') and i + 2 < len(lines):
            # Look for pattern: ===, # NAME, ===
            next_line = lines[i + 1]
            after_next = lines[i + 2]

            if next_line.startswith('# ') and after_next.startswith('# ===='):
                # Save previous section if any
                if current_section:
                    sections[current_section] = '\n'.join(section_lines).strip()

                # Extract section name (remove # and any trailing stuff like "(written to chain)")
                section_name = next_line[2:].strip()
                # Normalize: remove parenthetical notes, uppercase
                if '(' in section_name:
                    section_name = section_name[:section_name.index('(')].strip()
                current_section = section_name.upper()
                section_lines = []
                i += 3  # Skip the header
                continue

        # Add line to current section
        if current_section:
            section_lines.append(line)

        i += 1

    # Save last section
    if current_section:
        sections[current_section] = '\n'.join(section_lines).strip()

    return sections


def extract_actors_from_omt(omt_path: Path) -> Dict[str, str]:
    """Extract individual actor definitions from an .omt file.

    Returns a dict mapping actor name -> actor source code.
    """
    with open(omt_path) as f:
        content = f.read()

    actors = {}
    lines = content.split('\n')

    current_actor = None
    actor_lines = []
    paren_depth = 0

    for line in lines:
        # Check for actor start
        if line.startswith('actor ') and '(' in line:
            # Extract actor name
            parts = line.split('"')
            if len(parts) >= 1:
                name_part = line.split()[1]  # "actor Name" -> Name
                if '"' in name_part:
                    name_part = name_part.split('"')[0]
                current_actor = name_part
                actor_lines = [line]
                paren_depth = line.count('(') - line.count(')')
                continue

        if current_actor:
            actor_lines.append(line)
            paren_depth += line.count('(') - line.count(')')

            # Actor ends when parentheses balance
            if paren_depth <= 0:
                actors[current_actor] = '\n'.join(actor_lines)
                current_actor = None
                actor_lines = []

    return actors


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
            type_str = format_type_for_md(field.type)
            lines.append(f"  {field.name}: {type_str}")
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
            type_str = format_type_for_md(field.type)
            lines.append(f"  {field.name}: {type_str}")

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
                param_str = ", ".join(f"{p.name}: {format_type_for_md(p.type)}" for p in trigger.params)
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
                trigger = "auto" if trans.auto else format_trigger_for_md(trans.trigger)
                guard_str = f" [guard: {format_expr_for_md(trans.guard)}]" if trans.guard else ""

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
                val_str = format_expr_for_md(val)
                return f"STORE({key}, {val_str})"
            formatted = {k: format_expr_for_md(v) for k, v in action.assignments.items()}
            return f"STORE({formatted})"
        return f"store {', '.join(action.fields)}"
    elif isinstance(action, ComputeAction):
        expr_str = format_expr_for_md(action.expression)
        return f"compute {action.name} = {expr_str}"
    elif isinstance(action, LookupAction):
        expr_str = format_expr_for_md(action.expression)
        return f"lookup {action.name} = {expr_str}"
    elif isinstance(action, SendAction):
        target_str = format_expr_for_md(action.target)
        return f"SEND({target_str}, {action.message})"
    elif isinstance(action, BroadcastAction):
        target_str = format_expr_for_md(action.target_list)
        return f"BROADCAST({target_str}, {action.message})"
    elif isinstance(action, AppendAction):
        value_str = format_expr_for_md(action.value)
        return f"APPEND({action.list_name}, {value_str})"
    elif isinstance(action, AppendBlockAction):
        block_str = format_expr_for_md(action.block_type) if hasattr(action.block_type, 'name') else action.block_type
        return f"APPEND(chain, {block_str})"
    return str(action)


def generate_section_from_omt(section_content: str, title: str) -> str:
    """Generate markdown for a section using raw DSL source."""
    if not section_content:
        return f"## {title}\n\nNo {title.lower()} defined."

    lines = [f"## {title}\n"]
    lines.append("```omt")
    lines.append(section_content)
    lines.append("```")
    return "\n".join(lines)


def generate_actors_from_omt(actors: Dict[str, str]) -> str:
    """Generate markdown for actors using raw DSL source."""
    if not actors:
        return "No actors defined."

    lines = []
    for actor_name, actor_source in actors.items():
        lines.append(f"### Actor: {actor_name}\n")
        lines.append("```omt")
        lines.append(actor_source)
        lines.append("```\n")

    return "\n".join(lines)


def generate_markdown(tx_dir: Path, output_path: Path = None) -> str:
    """Generate full markdown documentation from transaction definition."""
    schema = load_transaction(tx_dir)
    commentary = load_commentary(tx_dir)

    # Extract raw sections from the .omt file
    omt_path = tx_dir / "transaction.omt"
    sections = extract_omt_sections(omt_path)
    actors = extract_actors_from_omt(omt_path)

    # Required sections - error if missing
    required_sections = ["PARAMETERS", "MESSAGES", "ACTORS"]
    missing = [s for s in required_sections if s not in sections and s != "ACTORS"]

    # Check actors separately
    if not actors:
        missing.append("ACTORS")

    if missing:
        raise ValueError(
            f"Missing required section headers in {omt_path}:\n"
            f"  {', '.join(missing)}\n"
            f"Each section must have a header like:\n"
            f"  # =============================================================================\n"
            f"  # SECTION_NAME\n"
            f"  # ============================================================================="
        )

    # Generate markdown using raw DSL source
    params_md = generate_section_from_omt(sections["PARAMETERS"], "Parameters")

    # Block types are optional
    if "BLOCK TYPES" in sections:
        blocks_md = generate_section_from_omt(sections["BLOCK TYPES"], "Block Types (Chain Records)")
    else:
        blocks_md = ""

    messages_md = generate_section_from_omt(sections["MESSAGES"], "Message Types")

    # Functions are optional
    if "FUNCTIONS" in sections:
        functions_md = generate_section_from_omt(sections["FUNCTIONS"], "Functions")
    else:
        functions_md = ""

    states_md = "## State Machines\n\n" + generate_actors_from_omt(actors)

    result = commentary
    result = result.replace("{{PARAMETERS}}", params_md)
    result = result.replace("{{BLOCKS}}", blocks_md)
    result = result.replace("{{MESSAGES}}", messages_md)
    result = result.replace("{{FUNCTIONS}}", functions_md)
    result = result.replace("{{STATE_MACHINES}}", states_md)

    if output_path:
        with open(output_path, "w") as f:
            f.write(result)
        print(f"Generated: {output_path}")

    return result


# =============================================================================
# PYTHON CODE GENERATION
# =============================================================================

def python_type(dsl_type) -> str:
    """Convert DSL type to Python type hint.

    Accepts either a string (legacy) or TypeExpr (new AST).
    """
    # Handle TypeExpr AST nodes using duck typing to avoid module path issues
    # Check class name instead of isinstance since module paths may differ
    type_class = type(dsl_type).__name__

    if type_class == 'ListType':
        inner_type = python_type(dsl_type.element_type)
        return f"List[{inner_type}]"
    if type_class == 'MapType':
        key_type = python_type(dsl_type.key_type)
        val_type = python_type(dsl_type.value_type)
        return f"Dict[{key_type}, {val_type}]"
    if type_class == 'SimpleType':
        dsl_type = dsl_type.name

    # Now dsl_type should be a string
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


def trigger_name(trigger) -> str:
    """Extract the trigger name from a trigger (string or TriggerExpr AST).

    Returns:
        - For string: returns the string
        - For MessageTrigger: returns the message_type
        - For TimeoutTrigger: returns "timeout(param)"
        - For NamedTrigger: returns the name
    """
    if trigger is None:
        return ""
    if isinstance(trigger, str):
        return trigger

    # Use duck typing to handle TriggerExpr AST nodes
    type_class = type(trigger).__name__
    if type_class == 'MessageTrigger':
        return trigger.message_type
    if type_class == 'TimeoutTrigger':
        return f"timeout({trigger.parameter})"
    if type_class == 'NamedTrigger':
        return trigger.name

    # Fallback to str conversion
    return str(trigger)


def is_timeout_trigger(trigger) -> bool:
    """Check if a trigger is a timeout trigger."""
    if trigger is None:
        return False
    if isinstance(trigger, str):
        return trigger.startswith("timeout(")

    type_class = type(trigger).__name__
    return type_class == 'TimeoutTrigger'


def expr_to_python(expr) -> str:
    """Convert an expression AST node to Python code.

    Accepts both strings (legacy) and Expr AST nodes.
    """
    if expr is None:
        return "None"
    if isinstance(expr, str):
        return expr

    type_class = type(expr).__name__

    if type_class == 'Identifier':
        return expr.name
    elif type_class == 'Literal':
        if expr.type == 'string':
            return f'"{expr.value}"'
        elif expr.type == 'bool':
            return 'True' if expr.value else 'False'
        elif expr.type == 'null':
            return 'None'
        else:
            return str(expr.value)
    elif type_class == 'BinaryExpr':
        left = expr_to_python(expr.left)
        right = expr_to_python(expr.right)
        op_map = {
            'ADD': '+', 'SUB': '-', 'MUL': '*', 'DIV': '/',
            'EQ': '==', 'NEQ': '!=', 'LT': '<', 'GT': '>',
            'LTE': '<=', 'GTE': '>=', 'AND': 'and', 'OR': 'or'
        }
        op = op_map.get(expr.op.name, str(expr.op.name))
        return f"({left} {op} {right})"
    elif type_class == 'UnaryExpr':
        operand = expr_to_python(expr.operand)
        if expr.op.name == 'NOT':
            return f"(not {operand})"
        elif expr.op.name == 'NEG':
            return f"(-{operand})"
        return operand
    elif type_class == 'IfExpr':
        cond = expr_to_python(expr.condition)
        then_e = expr_to_python(expr.then_expr)
        else_e = expr_to_python(expr.else_expr)
        return f"({then_e} if {cond} else {else_e})"
    elif type_class == 'FunctionCallExpr':
        args = ", ".join(expr_to_python(a) for a in expr.args)
        return f"{expr.name}({args})"
    elif type_class == 'FieldAccessExpr':
        obj = expr_to_python(expr.object)
        return f"{obj}.{expr.field}"
    elif type_class == 'DynamicFieldAccessExpr':
        obj = expr_to_python(expr.object)
        key = expr_to_python(expr.key_expr)
        return f"{obj}[{key}]"
    elif type_class == 'IndexAccessExpr':
        obj = expr_to_python(expr.object)
        index = expr_to_python(expr.index)
        return f"{obj}[{index}]"
    elif type_class == 'LambdaExpr':
        # Use DSL arrow syntax (v => body) for translator compatibility
        body = expr_to_python(expr.body)
        return f"{expr.param} => {body}"
    elif type_class == 'StructLiteralExpr':
        # Generate DSL-compatible syntax for the translator
        # Use DSL spread syntax (...var) not Python (**var)
        parts = []
        if expr.spread:
            spread = expr_to_python(expr.spread)
            parts.append(f"...{spread}")
        for k, v in expr.fields.items():
            parts.append(f"{k}: {expr_to_python(v)}")
        return "{ " + ", ".join(parts) + " }"
    elif type_class == 'ListLiteralExpr':
        elements = [expr_to_python(e) for e in expr.elements]
        return "[" + ", ".join(elements) + "]"
    elif type_class == 'EnumRefExpr':
        return f"{expr.enum_name}.{expr.value}"
    else:
        # Fallback to str conversion
        return str(expr)


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

        # Create AST translator
        parameters = {param.name for param in schema.parameters}
        enum_names = {enum.name for enum in schema.enums}
        enum_values = {}  # value_name -> enum_type
        for enum in schema.enums:
            for v in enum.values:
                enum_values[v.name] = enum.name
        self.expr_translator = ASTTranslator(self.store_vars, enum_names, enum_values, parameters)

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

        # Set message context for expression translation
        old_msg_var = self.expr_translator._msg_var
        self.expr_translator._msg_var = msg_var

        if isinstance(action, StoreAction):
            if action.assignments:
                # Store with explicit key=value assignments: STORE(key, value)
                for key, val in action.assignments.items():
                    # Guard: ensure val is AST node, not string expression
                    assert_is_ast_node(val, f"StoreAction assignment for '{key}'")
                    # Translate the AST expression directly
                    translated = self.expr_translator.translate(val)
                    # If storing the message object, store its payload instead
                    if translated == msg_var and msg_var:
                        translated = f"{msg_var}.payload"
                    lines.append(f'{ind}self.store("{key}", {translated})')
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
            from_expr_for_comment = " ".join(str(from_expr).split())  # for_comment - formatting only
            lines.append(f'{ind}# Compute: {var_name} = {from_expr_for_comment}')
            lines.append(f'{ind}self.store("{var_name}", self._compute_{var_name}())')

        elif isinstance(action, LookupAction):
            var_name = action.name
            from_expr = action.expression
            # Guard: ensure expression is AST node
            assert_is_ast_node(from_expr, f"LookupAction expression for '{var_name}'")
            # Translate the AST expression directly
            translated = self.expr_translator.translate(from_expr)
            lines.append(f'{ind}self.store("{var_name}", {translated})')

        elif isinstance(action, SendAction):
            msg_type = action.message
            to_target = action.target
            # Guard: ensure target is AST node
            assert_is_ast_node(to_target, f"SendAction target for '{msg_type}'")
            # Translate the AST expression directly
            recipient_expr = self.expr_translator.translate(to_target)

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
            # Extract the variable name from AST or string
            target_list_name = target_list.name if hasattr(target_list, 'name') else str(target_list)

            lines.append(f'{ind}for recipient in self.load("{target_list_name}", []):')
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
            # Extract the block type name from AST or string
            block_type = block_type.name if hasattr(block_type, 'name') else str(block_type)
            lines.append(f'{ind}self.chain.append(')
            lines.append(f'{ind}    BlockType.{block_type},')
            lines.append(f'{ind}    self._build_{block_type.lower()}_payload(),')
            lines.append(f'{ind}    current_time,')
            lines.append(f'{ind})')

        elif isinstance(action, AppendAction):
            list_name = action.list_name
            value = action.value

            # Special case: APPEND(chain, BLOCK_TYPE) is a chain append
            if list_name == "chain":
                # For chain append, need the block type name as a string
                block_type = value.name if hasattr(value, 'name') else str(value)
                lines.append(f'{ind}self.chain.append(')
                lines.append(f'{ind}    BlockType.{block_type},')
                lines.append(f'{ind}    self._build_{block_type.lower()}_payload(),')
                lines.append(f'{ind}    current_time,')
                lines.append(f'{ind})')
            else:
                # Translate the AST expression directly
                translated_value = self.expr_translator.translate(value)
                lines.append(f'{ind}_list = self.load("{list_name}") or []')
                lines.append(f'{ind}_list.append({translated_value})')
                lines.append(f'{ind}self.store("{list_name}", _list)')

        # Restore message context
        self.expr_translator._msg_var = old_msg_var

        return lines

    def _generate_external_trigger(self, trigger: TriggerDecl) -> str:
        """Generate external trigger method."""
        trig_name = trigger.name
        param_list = ", ".join(f"{p.name}: {python_type(p.type)}" for p in trigger.params)
        allowed_in = trigger.allowed_in

        lines = [f"    def {trig_name}(self{', ' + param_list if param_list else ''}):"]
        if trigger.description:
            lines.append(f'        """{trigger.description}"""')

        if allowed_in:
            allowed_states = ", ".join(f"{self.actor_name}State.{s}" for s in allowed_in)
            lines.append(f"        if self.state not in ({allowed_states},):")
            lines.append(f'            raise ValueError(f"Cannot {trig_name} in state {{self.state}}")')
            lines.append("")

        # Find transitions triggered by this external trigger
        for trans in self.actor.transitions:
            if trigger_name(trans.trigger) == trig_name and trans.from_state in allowed_in:
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
                     and not is_timeout_trigger(t.trigger)
                     and trigger_name(t.trigger) not in external_trigger_names]
        timeout_trans = [t for t in transitions if t.trigger and is_timeout_trigger(t.trigger)]

        # Handle message triggers first (check queue)
        for trans in msg_trans:
            trig = trans.trigger
            # Skip if it's an external trigger
            trig_name = trigger_name(trig)
            if trig_name in external_trigger_names:
                continue

            msg_type = trig_name
            lines.append(f"            # Check for {msg_type}")
            lines.append(f"            msgs = self.get_messages(MessageType.{msg_type})")
            lines.append("            if msgs:")
            lines.append("                _msg = msgs[0]")
            lines.extend(self._generate_transition_code(trans, indent_level=4, msg_var="_msg"))
            lines.append("                self.message_queue.remove(_msg)  # Only remove processed message")
            lines.append("")

        # Handle timeout transitions
        for trans in timeout_trans:
            trig = trans.trigger
            # Extract timeout parameter name from TimeoutTrigger or string
            type_class = type(trig).__name__
            if type_class == 'TimeoutTrigger':
                param_name = trig.parameter
            elif isinstance(trig, str) and trig.startswith("timeout(") and trig.endswith(")"):
                param_name = trig[8:-1]
            else:
                continue

            # Use state_entered_at which is automatically set by transition_to()
            lines.append(f"            # Timeout check")
            lines.append(f"            if self.current_time - self.load('state_entered_at', 0) > {param_name}:")
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

    def _generate_guard_check(self, guard) -> str:
        """Generate Python code for a guard check.

        Args:
            guard: Either a string (legacy) or Expr AST node
        """
        # Convert expression AST to string if needed
        guard_str = expr_to_python(guard) if not isinstance(guard, str) else guard
        sanitized = sanitize_guard_name(guard_str)
        return f"self._check_{sanitized}()"

def sanitize_guard_name(guard_name) -> str:
    """Convert an expression or guard name into a valid Python identifier.

    Args:
        guard_name: Either a string or Expr AST node
    """
    import re
    # Convert expression AST to string if needed
    if not isinstance(guard_name, str):
        guard_name = expr_to_python(guard_name)
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
    translator: 'ASTTranslator',
    local_vars: set,
    indent: int = 2
) -> None:
    """Generate Python code from function body statements.

    Args:
        statements: List of parsed statement AST nodes
        lines: Output list to append generated lines
        translator: ASTTranslator for DSL->Python conversion
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

    # Create AST translator
    store_vars = {field.name for field in actor.store}
    parameters = {param.name for param in schema.parameters}
    enum_names = {enum.name for enum in schema.enums}
    enum_values = {}
    for enum in schema.enums:
        for v in enum.values:
            enum_values[v.name] = enum.name
    translator = ASTTranslator(store_vars, enum_names, enum_values, parameters)

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
        # Guard: ensure expression is AST node
        assert_is_ast_node(expr, f"guard expression '{guard_name}'")
        # Translate AST expression directly
        translated = translator.translate(expr)
        # Get string repr for comment
        expr_str = expr_to_python(expr) if not isinstance(expr, str) else expr
        expr_for_comment = " ".join(expr_str.split())  # for_comment - formatting only

        lines.append(f"    def _check_{guard_name}(self) -> bool:")
        if desc:
            lines.append(f'        """{desc}"""')
        lines.append(f"        # Schema: {expr_for_comment[:60]}...")
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
            # Guard: ensure expression is AST node
            assert_is_ast_node(from_expr, f"compute expression for '{var_name}'")
            # Translate the expression
            translated = translator.translate(from_expr)
            # Convert to string for comment (expr_to_python handles both string and AST)
            from_expr_str = expr_to_python(from_expr) if not isinstance(from_expr, str) else from_expr
            lines.append(f"        # Schema: {from_expr_str[:60]}...")
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
                    bt = action.block_type.name if hasattr(action.block_type, 'name') else str(action.block_type)
                    block_types_to_build.add(bt)
            elif isinstance(action, AppendAction):
                # APPEND(chain, BLOCK_TYPE) is a chain append
                if action.list_name == "chain" and action.value:
                    bt = action.value.name if hasattr(action.value, 'name') else str(action.value)
                    block_types_to_build.add(bt)

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
    lines.append("        if chain is self.chain:")
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
    lines.append("        if chain is self.chain:")
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
        enum_names = {enum.name for enum in schema.enums}
        enum_values = {}
        for enum in schema.enums:
            for v in enum.values:
                enum_values[v.name] = enum.name
        func_translator = ASTTranslator(
            store_vars=set(),  # Function params are local, not store vars
            enum_names=enum_names,
            enum_values=enum_values,
            parameters=schema_params
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
    lines.append('        """Convert arguments to a hashable dict, recursively handling bytes."""')
    lines.append("        def convert(val):")
    lines.append("            if isinstance(val, bytes):")
    lines.append("                return val.hex()")
    lines.append("            if isinstance(val, (list, tuple)):")
    lines.append("                return [convert(v) for v in val]")
    lines.append("            if isinstance(val, dict):")
    lines.append("                return {k: convert(v) for k, v in val.items()}")
    lines.append("            if isinstance(val, Enum):")
    lines.append("                return val.name")
    lines.append("            return val")
    lines.append("        result = {}")
    lines.append("        for i, arg in enumerate(args):")
    lines.append("            result[f'_{i}'] = convert(arg)")
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
