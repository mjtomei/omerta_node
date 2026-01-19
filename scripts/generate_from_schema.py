#!/usr/bin/env python3
"""
Generate documentation and Python code from transaction schema.

Usage:
    python generate_from_schema.py <schema_dir> [--markdown] [--python] [--output-dir <dir>]

Example:
    python generate_from_schema.py docs/protocol/transactions/00_escrow_lock --markdown
    python generate_from_schema.py docs/protocol/transactions/00_escrow_lock --python --output-dir simulations/transactions
"""

import argparse
import yaml
import re
import sys
from pathlib import Path
from textwrap import dedent, indent
from typing import Dict, List, Any, Optional, Set


# =============================================================================
# EXPRESSION TRANSLATOR
# =============================================================================

class ExpressionTranslator:
    """Translate schema expressions to Python code."""

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

    # Functions that need self prefix (protocol-specific, from FORMAT.md)
    SELF_FUNCS = {
        # Chain operations
        'VERIFY_CHAIN_SEGMENT': '_verify_chain_segment',
        'CHAIN_CONTAINS_HASH': '_chain_contains_hash',
        'CHAIN_STATE_AT': '_chain_state_at',
        # Selection
        'SELECT_WITNESSES': '_select_witnesses',
        'SEEDED_RNG': '_seeded_rng',
        'SEEDED_SAMPLE': '_seeded_sample',
        # Compute
        'REMOVE': '_remove',
        'SORT': '_sort',
        'ABORT': '_abort',
        # Internal helpers
        '_to_hashable': '_to_hashable',
        # Lowercase aliases for compatibility
        'verify_chain_segment': '_verify_chain_segment',
        'chain_contains_hash': '_chain_contains_hash',
        'chain_state_at': '_chain_state_at',
        'select_witnesses': '_select_witnesses',
        'remove': '_remove',
    }

    def __init__(self, store_vars: Set[str], parameters: Set[str], enums: Dict[str, List[str]]):
        self.store_vars = store_vars
        self.parameters = parameters
        self.enums = enums  # Store full mapping for lookups
        # Build set of enum values for recognition
        self.enum_values = set()
        # Build reverse mapping: value -> enum name
        self.value_to_enum = {}
        for enum_name, values in enums.items():
            for val in values:
                self.enum_values.add(val)
                self.value_to_enum[val] = enum_name

    def get_enum_reference(self, value: str) -> Optional[str]:
        """Get enum reference for a value, e.g., 'ACCEPT' -> 'WitnessVerdict.ACCEPT'."""
        if value in self.value_to_enum:
            return f"{self.value_to_enum[value]}.{value}"
        return None

    def translate(self, expr: str) -> str:
        """Translate a schema expression to Python code."""
        if not expr:
            return "True"

        # Normalize whitespace
        expr = " ".join(expr.split())

        # Pre-process: transform hash(a + b + c) to hash(_to_bytes(a, b, c))
        expr = self._preprocess_hash_concat(expr)

        # Replace operators
        expr = expr.replace("&&", " and ")
        expr = expr.replace("||", " or ")
        expr = expr.replace("null", "None")

        # Translate function calls and variable references
        result = self._translate_tokens(expr)

        return result

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

                # Handle 'and', 'or', 'not', 'None', 'True', 'False'
                if token in ('and', 'or', 'not', 'None', 'True', 'False'):
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

                # Handle chain.method(...) - consume entire chain call
                if token == 'chain' and rest.startswith('.'):
                    # Find and consume .method_name
                    k = j
                    while k < len(expr) and expr[k].isspace():
                        k += 1
                    if k < len(expr) and expr[k] == '.':
                        k += 1  # skip the dot
                        while k < len(expr) and expr[k].isspace():
                            k += 1
                        m = k
                        while m < len(expr) and (expr[m].isalnum() or expr[m] == '_'):
                            m += 1
                        method_name = expr[k:m]
                        result.append(f'self.chain.{method_name}')
                        i = m
                        continue
                    else:
                        result.append('self.chain')
                        i = j
                        continue

                # Handle keyword arguments: identifier followed by = (but not ==)
                if rest.startswith('=') and not rest.startswith('=='):
                    # This is a keyword argument name - keep it as-is
                    result.append(token)
                    i = j
                    continue

                # Handle function calls
                if rest.startswith('('):
                    # Check for literal key functions (argument is NOT translated)
                    if token in self.LITERAL_KEY_FUNCS:
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
                        result.append(self.BUILTIN_FUNCS[token])
                    elif token in self.SELF_FUNCS:
                        result.append(f'self.{self.SELF_FUNCS[token]}')
                    else:
                        # Unknown function - keep as is but add self prefix
                        result.append(f'self._{token}')
                    i = j
                    continue

                # Handle attribute access on variables (e.g., pending_result.session_id)
                if rest.startswith('.'):
                    # Consume the variable and all attribute accesses
                    base = f'self.load("{token}")' if token not in self.ACTOR_PROPS else f'self.{token}'
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

                # Handle store variables
                if token in self.store_vars:
                    result.append(f'self.load("{token}")')
                    i = j
                    continue

                # Unknown identifier - assume it's a store variable
                result.append(f'self.load("{token}")')
                i = j
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


def load_schema(schema_dir: Path) -> dict:
    """Load schema.yaml from directory."""
    schema_path = schema_dir / "schema.yaml"
    if not schema_path.exists():
        raise FileNotFoundError(f"Schema not found: {schema_path}")

    with open(schema_path) as f:
        schema = yaml.safe_load(f)

    # Validate schema - disallow object and list[object] types
    validate_no_object_types(schema)

    return schema


def validate_no_object_types(schema: dict) -> None:
    """Validate that schema doesn't use 'object' or 'list[object]' types.

    These types are disallowed - use explicit struct types instead.
    """
    errors = []

    # Check types section
    for type_name, type_def in schema.get("types", {}).items():
        if isinstance(type_def, dict) and "fields" in type_def:
            for field_name, field_def in type_def["fields"].items():
                field_type = field_def.get("type", "") if isinstance(field_def, dict) else field_def
                if _is_disallowed_type(field_type):
                    errors.append(f"types.{type_name}.{field_name}: '{field_type}' is not allowed. Use explicit struct types.")

    # Check messages section
    for msg_name, msg_def in schema.get("messages", {}).items():
        if isinstance(msg_def, dict) and "fields" in msg_def:
            for field_name, field_def in msg_def["fields"].items():
                field_type = field_def.get("type", "") if isinstance(field_def, dict) else ""
                if _is_disallowed_type(field_type):
                    errors.append(f"messages.{msg_name}.{field_name}: '{field_type}' is not allowed. Use explicit struct types.")

    # Check actors' store_schema
    for actor_name, actor_def in schema.get("actors", {}).items():
        if isinstance(actor_def, dict) and "store_schema" in actor_def:
            for field_name, field_type in actor_def["store_schema"].items():
                if _is_disallowed_type(field_type):
                    errors.append(f"actors.{actor_name}.store_schema.{field_name}: '{field_type}' is not allowed. Use explicit struct types.")

    if errors:
        error_msg = "Schema validation failed - disallowed types found:\n" + "\n".join(f"  - {e}" for e in errors)
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


def load_commentary(schema_dir: Path) -> str:
    """Load commentary.md from directory."""
    commentary_path = schema_dir / "commentary.md"
    if not commentary_path.exists():
        return ""

    with open(commentary_path) as f:
        return f.read()


# =============================================================================
# MARKDOWN GENERATION
# =============================================================================

def generate_parameters_markdown(schema: dict) -> str:
    """Generate parameters table markdown."""
    params = schema.get("parameters", {})
    if not params:
        return "No parameters defined."

    lines = ["## Parameters\n"]
    lines.append("| Parameter | Value | Description |")
    lines.append("|-----------|-------|-------------|")

    for name, info in params.items():
        value = info.get("value", "")
        unit = info.get("unit", "")
        if unit:
            value = f"{value} {unit}"
        desc = info.get("description", "")
        lines.append(f"| `{name}` | {value} | {desc} |")

    return "\n".join(lines)


def generate_blocks_markdown(schema: dict) -> str:
    """Generate block types markdown."""
    blocks = schema.get("blocks", {})
    if not blocks:
        return "No block types defined."

    lines = ["## Block Types (Chain Records)\n"]
    lines.append("```")

    for name, info in blocks.items():
        desc = info.get("description", "")
        lines.append(f"{name} {{")
        if desc:
            lines.append(f"  # {desc}")
        for field_name, field_info in info.get("fields", {}).items():
            ftype = field_info.get("type", "any")
            required = field_info.get("required", False)
            req_str = "" if required else " (optional)"
            lines.append(f"  {field_name}: {ftype}{req_str}")
        lines.append("}\n")

    lines.append("```")
    return "\n".join(lines)


def generate_messages_markdown(schema: dict) -> str:
    """Generate message types markdown."""
    messages = schema.get("messages", {})
    if not messages:
        return "No messages defined."

    lines = ["## Message Types\n"]
    lines.append("```")

    for name, info in messages.items():
        sender = info.get("sender", "?")
        recipients = info.get("recipients", [])
        recipients_str = ", ".join(recipients) if isinstance(recipients, list) else recipients
        desc = info.get("description", "")

        lines.append(f"# {sender} -> {recipients_str}")
        if desc:
            lines.append(f"# {desc}")
        lines.append(f"{name} {{")

        for field_name, field_info in info.get("fields", {}).items():
            if isinstance(field_info, dict):
                ftype = field_info.get("type", "any")
                required = field_info.get("required", False)
                req_str = "" if required else " (optional)"
            else:
                ftype = field_info
                req_str = ""
            lines.append(f"  {field_name}: {ftype}{req_str}")

        signed_by = info.get("signed_by", "")
        if signed_by:
            lines.append(f"  signature: bytes  # signed by {signed_by}")

        lines.append("}\n")

    lines.append("```")
    return "\n".join(lines)


def generate_state_machines_markdown(schema: dict) -> str:
    """Generate state machine diagrams markdown."""
    actors = schema.get("actors", {})
    if not actors:
        return "No actors defined."

    lines = []

    for actor_name, actor_info in actors.items():
        lines.append(f"### ACTOR: {actor_name}\n")
        desc = actor_info.get("description", "")
        if desc:
            lines.append(f"*{desc}*\n")

        lines.append("```")

        # States
        states = actor_info.get("states", {})
        state_names = list(states.keys())
        lines.append(f"STATES: [{', '.join(state_names)}]")
        lines.append("")

        initial = actor_info.get("initial_state", state_names[0] if state_names else "IDLE")
        lines.append(f"INITIAL: {initial}")
        lines.append("")

        # External triggers
        triggers = actor_info.get("external_triggers", {})
        if triggers:
            lines.append("EXTERNAL TRIGGERS:")
            for trigger_name, trigger_info in triggers.items():
                params = trigger_info.get("params", {})
                allowed_in = trigger_info.get("allowed_in", [])
                param_str = ", ".join(f"{k}: {v}" for k, v in params.items()) if isinstance(params, dict) else ", ".join(params)
                lines.append(f"  {trigger_name}({param_str})")
                lines.append(f"    allowed_in: [{', '.join(allowed_in)}]")
            lines.append("")

        # States with descriptions
        for state_name, state_info in states.items():
            state_desc = state_info.get("description", "")
            terminal = state_info.get("terminal", False)
            term_str = " [TERMINAL]" if terminal else ""
            lines.append(f"STATE {state_name}:{term_str}")
            if state_desc:
                lines.append(f"  # {state_desc}")
            lines.append("")

        # Transitions
        transitions = actor_info.get("transitions", [])
        if transitions:
            lines.append("TRANSITIONS:")
            for trans in transitions:
                from_state = trans.get("from", "?")
                trigger = trans.get("trigger", "?")
                to_state = trans.get("to", "?")
                guard = trans.get("guard", "")
                guard_str = f" [guard: {guard}]" if guard else ""

                lines.append(f"  {from_state} --{trigger}-->{guard_str} {to_state}")

                actions = trans.get("actions", [])
                for action in actions[:3]:
                    if isinstance(action, dict):
                        action_str = str(action)[:60] + "..." if len(str(action)) > 60 else str(action)
                    else:
                        action_str = str(action)
                    lines.append(f"    action: {action_str}")

                if len(actions) > 3:
                    lines.append(f"    ... and {len(actions) - 3} more actions")

        lines.append("```\n")

    return "\n".join(lines)


def generate_markdown(schema_dir: Path, output_path: Path = None) -> str:
    """Generate full markdown documentation from schema and commentary."""
    schema = load_schema(schema_dir)
    commentary = load_commentary(schema_dir)

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

def python_type(schema_type: str) -> str:
    """Convert schema type to Python type hint."""
    type_map = {
        "hash": "str",
        "peer_id": "str",
        "bytes": "bytes",
        "uint": "int",
        "float": "float",
        "timestamp": "float",
        "string": "str",
        "bool": "bool",
        "signature": "str",
        "object": "Dict[str, Any]",
        "any": "Any",
    }

    if schema_type.startswith("list["):
        inner = schema_type[5:-1]
        return f"List[{python_type(inner)}]"
    if schema_type.startswith("map["):
        parts = schema_type[4:-1].split(",")
        key = python_type(parts[0].strip())
        val = python_type(parts[1].strip()) if len(parts) > 1 else "Any"
        return f"Dict[{key}, {val}]"

    return type_map.get(schema_type, schema_type)


def generate_parameters_python(schema: dict) -> str:
    """Generate Python parameter constants."""
    params = schema.get("parameters", {})
    if not params:
        return ""

    lines = ["# ============================================================================="]
    lines.append("# Parameters (from schema)")
    lines.append("# =============================================================================")
    lines.append("")

    for name, info in params.items():
        value = info.get("value", 0)
        desc = info.get("description", "")
        unit = info.get("unit", "")

        if isinstance(value, float) and value == int(value):
            value = int(value)

        comment = f"  # {desc}"
        if unit:
            comment += f" ({unit})"

        lines.append(f"{name} = {value}{comment}")

    lines.append("")
    return "\n".join(lines)


def generate_enums_python(schema: dict) -> str:
    """Generate Python enums."""
    enums = schema.get("enums", {})
    if not enums:
        return ""

    lines = ["# ============================================================================="]
    lines.append("# Enums")
    lines.append("# =============================================================================")
    lines.append("")

    for enum_name, enum_info in enums.items():
        desc = enum_info.get("description", "")
        values = enum_info.get("values", [])

        lines.append(f"class {enum_name}(Enum):")
        if desc:
            lines.append(f'    """{desc}"""')
        for val in values:
            lines.append(f"    {val} = auto()")
        lines.append("")

    return "\n".join(lines)


def generate_messages_python(schema: dict) -> str:
    """Generate Python message types."""
    messages = schema.get("messages", {})
    if not messages:
        return ""

    lines = ["# ============================================================================="]
    lines.append("# Message Types")
    lines.append("# =============================================================================")
    lines.append("")
    lines.append("class MessageType(Enum):")
    lines.append('    """Types of messages exchanged in this transaction."""')

    for name in messages.keys():
        lines.append(f"    {name} = auto()")

    lines.append("")
    lines.append("")
    lines.append("@dataclass")
    lines.append("class Message:")
    lines.append('    """A message between actors."""')
    lines.append("    msg_type: MessageType")
    lines.append("    sender: str")
    lines.append("    payload: Dict[str, Any]")
    lines.append("    timestamp: float")
    lines.append("")

    return "\n".join(lines)


class PythonActorGenerator:
    """Generate complete Python actor class from schema."""

    def __init__(self, actor_name: str, actor_info: dict, schema: dict):
        self.actor_name = actor_name
        self.actor_info = actor_info
        self.schema = schema
        self.states = actor_info.get("states", {})
        self.transitions = actor_info.get("transitions", [])
        self.external_triggers = actor_info.get("external_triggers", {})
        self.guards = actor_info.get("guards", {})
        self.messages = schema.get("messages", {})
        # Collect all known store variable names
        self.store_vars = set(actor_info.get("store_schema", {}).keys())

        # Create expression translator
        parameters = set(schema.get("parameters", {}).keys())
        enums = {}
        for enum_name, enum_info in schema.get("enums", {}).items():
            if isinstance(enum_info, dict):
                values = enum_info.get("values", [])
                if isinstance(values, list):
                    enums[enum_name] = values
                elif isinstance(values, dict):
                    enums[enum_name] = list(values.keys())
            elif isinstance(enum_info, list):
                enums[enum_name] = enum_info
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

        desc = self.actor_info.get("description", "")
        if desc:
            lines.append(f'    """{desc}"""')
        lines.append("")

        initial = self.actor_info.get("initial_state", "IDLE")
        lines.append(f"    state: {self.actor_name}State = {self.actor_name}State.{initial}")

        # Actor-specific attributes
        if self.actor_name == "Witness":
            lines.append("    cached_chains: Dict[str, dict] = field(default_factory=dict)")
        lines.append("")

        # Actor-specific properties
        if self.actor_name == "Consumer":
            lines.append("    @property")
            lines.append("    def is_locked(self) -> bool:")
            lines.append('        """Check if consumer is in LOCKED state."""')
            lines.append(f"        return self.state == {self.actor_name}State.LOCKED")
            lines.append("")
            lines.append("    @property")
            lines.append("    def is_failed(self) -> bool:")
            lines.append('        """Check if consumer is in FAILED state."""')
            lines.append(f"        return self.state == {self.actor_name}State.FAILED")
            lines.append("")
            lines.append("    @property")
            lines.append("    def total_escrowed(self) -> float:")
            lines.append('        """Get total escrowed amount."""')
            lines.append('        return self.load("total_escrowed", 0.0)')
            lines.append("")

        # External trigger methods
        for trigger_name, trigger_info in self.external_triggers.items():
            lines.append(self._generate_external_trigger(trigger_name, trigger_info))
            lines.append("")

        # Tick method
        lines.append(self._generate_tick_method())

        return "\n".join(lines)

    def _generate_state_enum(self) -> str:
        """Generate state enum."""
        lines = [f"class {self.actor_name}State(Enum):"]
        desc = self.actor_info.get("description", "")
        if desc:
            lines.append(f'    """{self.actor_name} states."""')

        for state_name, state_info in self.states.items():
            state_desc = state_info.get("description", "")
            if state_desc:
                lines.append(f"    {state_name} = auto()  # {state_desc}")
            else:
                lines.append(f"    {state_name} = auto()")

        return "\n".join(lines)

    def _generate_external_trigger(self, trigger_name: str, trigger_info: dict) -> str:
        """Generate external trigger method."""
        params = trigger_info.get("params", {})
        trigger_desc = trigger_info.get("description", "")
        allowed_in = trigger_info.get("allowed_in", [])

        if isinstance(params, dict):
            param_list = ", ".join(f"{k}: {python_type(v)}" for k, v in params.items())
        else:
            param_list = ", ".join(f"{p}: Any" for p in params)

        lines = [f"    def {trigger_name}(self{', ' + param_list if param_list else ''}):"]
        if trigger_desc:
            lines.append(f'        """{trigger_desc}"""')

        if allowed_in:
            allowed_states = ", ".join(f"{self.actor_name}State.{s}" for s in allowed_in)
            lines.append(f"        if self.state not in ({allowed_states},):")
            lines.append(f'            raise ValueError(f"Cannot {trigger_name} in state {{self.state}}")')
            lines.append("")

        # Find transitions triggered by this external trigger
        for trans in self.transitions:
            if trans.get("trigger") == trigger_name and trans.get("from") in allowed_in:
                guard = trans.get("guard", "")
                on_guard_fail = trans.get("on_guard_fail", {})

                # Execute actions first
                actions = trans.get("actions", [])
                for action in actions:
                    if isinstance(action, dict):
                        lines.extend(self._generate_action_code(action, indent_level=2, msg_var=None))
                    elif isinstance(action, str):
                        lines.append(f"        # Action: {action}")

                # If there's a guard, check it after actions
                if guard:
                    guard_code = self._generate_guard_check(guard)
                    lines.append(f"        if {guard_code}:")
                    to_state = trans.get("to", "")
                    if to_state:
                        lines.append(f"            self.transition_to({self.actor_name}State.{to_state})")

                    # Handle guard failure
                    if on_guard_fail:
                        lines.append("        else:")
                        # Process actions in on_guard_fail
                        fail_actions = on_guard_fail.get("actions", [])
                        for action in fail_actions:
                            if isinstance(action, dict):
                                lines.extend(["    " + l for l in self._generate_action_code(action, indent_level=2, msg_var=None)])
                        fail_store = on_guard_fail.get("store", {})
                        if fail_store:
                            for key, val in fail_store.items():
                                lines.append(f'            self.store("{key}", "{val}")')
                        fail_target = on_guard_fail.get("target", "")
                        if fail_target:
                            lines.append(f"            self.transition_to({self.actor_name}State.{fail_target})")
                else:
                    # No guard - just transition
                    to_state = trans.get("to", "")
                    if to_state:
                        lines.append(f"        self.transition_to({self.actor_name}State.{to_state})")
                break
        else:
            # No matching transition found - store params and transition
            if isinstance(params, dict):
                for param_name in params.keys():
                    lines.append(f'        self.store("{param_name}", {param_name})')
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
        transitions_by_state: Dict[str, List[dict]] = {}
        for trans in self.transitions:
            from_state = trans.get("from", "")
            if from_state not in transitions_by_state:
                transitions_by_state[from_state] = []
            transitions_by_state[from_state].append(trans)

        first = True
        for state_name, state_info in self.states.items():
            prefix = "if" if first else "elif"
            first = False

            lines.append(f"        {prefix} self.state == {self.actor_name}State.{state_name}:")

            state_transitions = transitions_by_state.get(state_name, [])
            if not state_transitions:
                # No transitions - passive state
                state_desc = state_info.get("description", "")
                if state_desc:
                    lines.append(f"            # {state_desc}")
                lines.append("            pass")
            else:
                lines.extend(self._generate_state_body(state_name, state_transitions))

            lines.append("")

        lines.append("        return outgoing")
        return "\n".join(lines)

    def _generate_state_body(self, state_name: str, transitions: List[dict]) -> List[str]:
        """Generate the body of a state handler."""
        lines = []

        # Separate transitions by trigger type
        auto_trans = [t for t in transitions if t.get("trigger") == "auto"]
        msg_trans = [t for t in transitions if t.get("trigger", "").startswith("timeout(") is False
                     and t.get("trigger") != "auto"
                     and t.get("trigger") not in self.external_triggers]
        timeout_trans = [t for t in transitions if str(t.get("trigger", "")).startswith("timeout(")]
        external_trans = [t for t in transitions if t.get("trigger") in self.external_triggers]

        # Handle message triggers first (check queue)
        for trans in msg_trans:
            trigger = trans.get("trigger", "")
            # Skip if it's an external trigger
            if trigger in self.external_triggers:
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
            trigger = trans.get("trigger", "")
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
        for trans in auto_trans:
            guard = trans.get("guard", "")
            if guard:
                guard_code = self._generate_guard_check(guard)
                lines.append(f"            # Auto transition with guard: {guard}")
                lines.append(f"            if {guard_code}:")
                lines.extend(self._generate_transition_code(trans, indent_level=4))

                # Handle guard failure
                on_fail = trans.get("on_guard_fail", {})
                if on_fail:
                    lines.append("            else:")
                    # Process actions in on_guard_fail
                    fail_actions = on_fail.get("actions", [])
                    for action in fail_actions:
                        if isinstance(action, dict):
                            lines.extend(["    " + l for l in self._generate_action_code(action, indent_level=3, msg_var=None)])
                    fail_target = on_fail.get("target", "")
                    fail_store = on_fail.get("store", {})
                    if fail_store:
                        for key, val in fail_store.items():
                            lines.append(f'                self.store("{key}", "{val}")')
                    if fail_target:
                        lines.append(f"                self.transition_to({self.actor_name}State.{fail_target})")
            else:
                lines.append("            # Auto transition")
                lines.extend(self._generate_transition_code(trans, indent_level=3))

        # If no transitions generated anything, add pass
        if not lines:
            lines.append("            pass")

        return lines

    def _generate_transition_code(self, trans: dict, indent_level: int = 3, msg_var: str = None) -> List[str]:
        """Generate code for a transition's actions."""
        lines = []
        ind = "    " * indent_level

        actions = trans.get("actions", [])
        to_state = trans.get("to", "")

        for action in actions:
            if isinstance(action, dict):
                lines.extend(self._generate_action_code(action, indent_level, msg_var))
            elif isinstance(action, str):
                lines.append(f"{ind}# Action: {action}")

        if to_state:
            lines.append(f"{ind}self.transition_to({self.actor_name}State.{to_state})")

        return lines

    def _generate_action_code(self, action: dict, indent_level: int, msg_var: str = None) -> List[str]:
        """Generate code for a single action."""
        lines = []
        ind = "    " * indent_level

        if "store" in action:
            store_val = action["store"]
            if isinstance(store_val, list):
                # Store multiple fields from params - these are function arguments
                for field in store_val:
                    lines.append(f'{ind}self.store("{field}", {field})')
            elif isinstance(store_val, dict):
                for key, val in store_val.items():
                    if isinstance(val, str):
                        # Check for special patterns
                        if val.startswith("message."):
                            # Expression referencing message - translate to msg
                            msg_attr = val[8:]  # Remove "message." prefix
                            msg = msg_var or "msg"
                            lines.append(f'{ind}self.store("{key}", {msg}.{msg_attr})')
                        elif val in ExpressionTranslator.ACTOR_PROPS:
                            # It's an actor property (current_time, peer_id, etc.)
                            lines.append(f'{ind}self.store("{key}", self.{val})')
                        elif val in self.store_vars:
                            # It's a variable reference - load it from store
                            lines.append(f'{ind}self.store("{key}", self.load("{val}"))')
                        else:
                            # Check if it's an enum value
                            enum_ref = self.expr_translator.get_enum_reference(val)
                            if enum_ref:
                                lines.append(f'{ind}self.store("{key}", {enum_ref})')
                            else:
                                # It's a string literal
                                lines.append(f'{ind}self.store("{key}", {repr(val)})')
                    else:
                        lines.append(f'{ind}self.store("{key}", {repr(val)})')

        elif "store_from_message" in action:
            fields = action["store_from_message"]
            if isinstance(fields, list):
                for field in fields:
                    lines.append(f'{ind}self.store("{field}", {msg_var or "msg"}.payload.get("{field}"))')
            elif isinstance(fields, dict):
                for local_key, msg_key in fields.items():
                    if msg_key == "message":
                        # Store the whole message payload
                        lines.append(f'{ind}self.store("{local_key}", {msg_var or "msg"}.payload)')
                    else:
                        lines.append(f'{ind}self.store("{local_key}", {msg_var or "msg"}.payload.get("{msg_key}"))')

        elif "compute" in action:
            compute_val = action["compute"]
            if isinstance(compute_val, str):
                # Form: { compute: var_name, from: "..." }
                var_name = compute_val
                from_expr = action.get("from", "")
            elif isinstance(compute_val, dict):
                # Form: { compute: { var_name: ..., from: "..." } }
                from_expr = compute_val.get("from", "")
                # Find the var name (key that's not "from")
                var_name = None
                for key in compute_val.keys():
                    if key != "from":
                        var_name = key
                        break
                if not var_name:
                    var_name = "computed_value"
            else:
                var_name = "computed_value"
                from_expr = ""
            # Generate a simplified version - full expression parsing would be complex
            from_expr_oneline = " ".join(str(from_expr).split())
            lines.append(f'{ind}# Compute: {var_name} = {from_expr_oneline}')
            lines.append(f'{ind}self.store("{var_name}", self._compute_{var_name}())')

        elif "send" in action:
            send_info = action["send"]
            msg_type = send_info.get("message", "")
            to_target = send_info.get("to", "")
            inline_fields = send_info.get("fields", {})

            if to_target.startswith("each("):
                # Send to multiple recipients
                list_name = to_target[5:-1]
                lines.append(f'{ind}for recipient in self.load("{list_name}", []):')
                if inline_fields:
                    # Build payload inline with provided fields
                    lines.append(f'{ind}    msg_payload = {{')
                    for field_name, field_val in inline_fields.items():
                        lines.append(f'{ind}        "{field_name}": {repr(field_val)},')
                    lines.append(f'{ind}        "timestamp": current_time,')
                    lines.append(f'{ind}    }}')
                else:
                    lines.append(f'{ind}    msg_payload = self._build_{msg_type.lower()}_payload()')
                lines.append(f'{ind}    outgoing.append(Message(')
                lines.append(f'{ind}        msg_type=MessageType.{msg_type},')
                lines.append(f'{ind}        sender=self.peer_id,')
                lines.append(f'{ind}        payload=msg_payload,')
                lines.append(f'{ind}        timestamp=current_time,')
                lines.append(f'{ind}    ))')
            else:
                if inline_fields:
                    # Build payload inline with provided fields
                    lines.append(f'{ind}msg_payload = {{')
                    for field_name, field_val in inline_fields.items():
                        lines.append(f'{ind}    "{field_name}": {repr(field_val)},')
                    lines.append(f'{ind}    "timestamp": current_time,')
                    lines.append(f'{ind}}}')
                else:
                    lines.append(f'{ind}msg_payload = self._build_{msg_type.lower()}_payload()')
                lines.append(f'{ind}outgoing.append(Message(')
                lines.append(f'{ind}    msg_type=MessageType.{msg_type},')
                lines.append(f'{ind}    sender=self.peer_id,')
                lines.append(f'{ind}    payload=msg_payload,')
                lines.append(f'{ind}    timestamp=current_time,')
                lines.append(f'{ind}))')

        elif "append_block" in action:
            block_info = action["append_block"]
            block_type = block_info.get("type", "")
            lines.append(f'{ind}self.chain.append(')
            lines.append(f'{ind}    BlockType.{block_type},')
            lines.append(f'{ind}    self._build_{block_type.lower()}_payload(),')
            lines.append(f'{ind}    current_time,')
            lines.append(f'{ind})')

        elif "lookup" in action:
            # Lookup action: retrieve data from chain and store
            var_name = action["lookup"]
            from_expr = action.get("from", "")

            # Special handling for chain.get_peer_hash - extracts hash and timestamp
            if "get_peer_hash" in from_expr:
                # Extract the peer argument
                peer_match = re.search(r'get_peer_hash\((\w+)\)', from_expr)
                peer_var = peer_match.group(1) if peer_match else "peer"
                lines.append(f'{ind}_lookup_block = self.chain.get_peer_hash(self.load("{peer_var}"))')
                lines.append(f'{ind}if _lookup_block:')
                lines.append(f'{ind}    self.store("{var_name}", _lookup_block.payload.get("hash"))')
                lines.append(f'{ind}    self.store("{var_name}_timestamp", _lookup_block.timestamp)')
            else:
                # Generic lookup - store the raw result
                translated = self.expr_translator.translate(from_expr) if hasattr(self, 'expr_translator') else from_expr
                lines.append(f'{ind}self.store("{var_name}", {translated})')

        elif "append" in action:
            # Append to a list: { append: { list_name: value } }
            append_info = action["append"]
            for list_name, value in append_info.items():
                if isinstance(value, str):
                    if value.startswith("message."):
                        # Reference to message field
                        msg_attr = value[8:]
                        msg = msg_var or "msg"
                        lines.append(f'{ind}_list = self.load("{list_name}") or []')
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

    def _generate_guard_check(self, guard_name: str) -> str:
        """Generate Python code for a guard check."""
        sanitized = sanitize_guard_name(guard_name)
        return f"self._check_{sanitized}()"

    def _infer_started_at_key(self, state_name: str) -> str:
        """Infer the 'started_at' key for timeout checking."""
        state_lower = state_name.lower()
        if "waiting" in state_lower:
            # Try to find what we're waiting for
            if "commitment" in state_lower:
                return "intent_sent_at"
            elif "result" in state_lower:
                return "requests_sent_at"
            elif "signature" in state_lower:
                return "propagated_at"
            elif "topup" in state_lower:
                return "topup_sent_at"
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


def generate_actor_helpers(actor_name: str, actor_info: dict, schema: dict) -> str:
    """Generate helper methods for an actor (payload builders, guards, etc.)."""
    lines = []
    transitions = actor_info.get("transitions", [])
    guards = actor_info.get("guards", {})
    messages = schema.get("messages", {})

    # Create expression translator
    store_vars = set(actor_info.get("store_schema", {}).keys())
    parameters = set(schema.get("parameters", {}).keys())
    enums = {}
    for enum_name, enum_info in schema.get("enums", {}).items():
        if isinstance(enum_info, dict):
            values = enum_info.get("values", [])
            if isinstance(values, list):
                enums[enum_name] = values
            elif isinstance(values, dict):
                enums[enum_name] = list(values.keys())
        elif isinstance(enum_info, list):
            enums[enum_name] = enum_info
    translator = ExpressionTranslator(store_vars, parameters, enums)

    # Collect all message types we need to build
    msg_types_to_build = set()
    for trans in transitions:
        for action in trans.get("actions", []):
            if isinstance(action, dict) and "send" in action:
                msg_type = action["send"].get("message", "")
                if msg_type:
                    msg_types_to_build.add(msg_type)

    # Generate payload builder methods
    for msg_type in msg_types_to_build:
        msg_info = messages.get(msg_type, {})
        lines.append(f"    def _build_{msg_type.lower()}_payload(self) -> Dict[str, Any]:")
        lines.append(f'        """Build payload for {msg_type} message."""')
        lines.append("        payload = {")

        for field_name, field_info in msg_info.get("fields", {}).items():
            if field_name == "timestamp":
                continue  # Skip timestamp - we add it explicitly
            if isinstance(field_info, dict) and field_info.get("type") == "object":
                # For nested objects, load from store with same name
                lines.append(f'            "{field_name}": self.load("{field_name}"),')
                continue
            lines.append(f'            "{field_name}": self._serialize_value(self.load("{field_name}")),')

        lines.append("            \"timestamp\": self.current_time,")
        lines.append("        }")

        # Add signature if needed
        signed_by = msg_info.get("signed_by", "")
        if signed_by:
            lines.append("        payload[\"signature\"] = sign(self.chain.private_key, hash_data(payload))")

        lines.append("        return payload")
        lines.append("")

    # Collect all guards - both named guards and inline guard expressions
    all_guards = {}  # sanitized_name -> (description, expression)

    # Add named guards from guards dict
    for guard_name, guard_info in guards.items():
        desc = guard_info.get("description", "")
        expr = guard_info.get("expression", "True")
        all_guards[guard_name] = (desc, expr)

    # Add inline guards from transitions
    for trans in transitions:
        guard = trans.get("guard", "")
        if guard and guard not in guards:
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
        for action in trans.get("actions", []):
            if isinstance(action, dict) and "compute" in action:
                compute_val = action["compute"]
                from_expr = action.get("from", "")
                if isinstance(compute_val, str):
                    # Form: { compute: var_name, from: "..." }
                    if compute_val not in compute_exprs:
                        compute_exprs[compute_val] = from_expr
                elif isinstance(compute_val, dict):
                    # Form: { compute: { var_name: ..., from: "..." } }
                    from_expr = compute_val.get("from", "")
                    for key in compute_val.keys():
                        if key != "from":
                            if key not in compute_exprs:
                                compute_exprs[key] = from_expr

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
        for action in trans.get("actions", []):
            if isinstance(action, dict) and "append_block" in action:
                block_type = action["append_block"].get("type", "")
                if block_type:
                    block_types_to_build.add(block_type)

    # Generate block payload builders
    blocks = schema.get("blocks", {})
    for block_type in block_types_to_build:
        block_info = blocks.get(block_type, {})
        lines.append(f"    def _build_{block_type.lower()}_payload(self) -> Dict[str, Any]:")
        lines.append(f'        """Build payload for {block_type} chain block."""')
        lines.append("        return {")

        for field_name in block_info.get("fields", {}).keys():
            if field_name == "timestamp":
                lines.append(f'            "timestamp": self.current_time,')
            else:
                lines.append(f'            "{field_name}": self.load("{field_name}"),')

        lines.append("        }")
        lines.append("")

    # Generate protocol function implementations (matching FORMAT.md primitives)
    # These are fully functional, not placeholders

    # _verify_chain_segment
    lines.append("    def _verify_chain_segment(self, segment: List[dict]) -> bool:")
    lines.append('        """VERIFY_CHAIN_SEGMENT: Verify a chain segment is valid."""')
    lines.append("        if not segment:")
    lines.append("            return False")
    lines.append("        # Verify hash chain integrity")
    lines.append("        for i in range(1, len(segment)):")
    lines.append('            if segment[i].get("previous_hash") != segment[i-1].get("block_hash"):')
    lines.append("                return False")
    lines.append("            if segment[i].get(\"sequence\") != i:")
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
    lines.append("            # It's a segment - find the block and build state")
    lines.append("            target_idx = None")
    lines.append("            for i, block in enumerate(chain_or_segment):")
    lines.append("                if block.get('block_hash') == target_hash:")
    lines.append("                    target_idx = i")
    lines.append("                    break")
    lines.append("            if target_idx is None:")
    lines.append("                return None")
    lines.append("            # Build state from blocks up to target")
    lines.append("            state = {")
    lines.append('                "known_peers": set(),')
    lines.append('                "peer_hashes": {},')
    lines.append('                "balance_locks": [],')
    lines.append('                "block_hash": target_hash,')
    lines.append('                "sequence": target_idx,')
    lines.append("            }")
    lines.append("            for block in chain_or_segment[:target_idx + 1]:")
    lines.append("                if block.get('block_type') == 'peer_hash':")
    lines.append("                    peer = block.get('payload', {}).get('peer')")
    lines.append("                    if peer:")
    lines.append('                        state["known_peers"].add(peer)')
    lines.append('                        state["peer_hashes"][peer] = block.get("payload", {}).get("hash")')
    lines.append("                elif block.get('block_type') == 'balance_lock':")
    lines.append('                    state["balance_locks"].append(block.get("payload", {}))')
    lines.append('            state["known_peers"] = list(state["known_peers"])')
    lines.append("            return state")
    lines.append("        elif hasattr(chain_or_segment, 'get_state_at'):")
    lines.append("            # It's a Chain object")
    lines.append("            return chain_or_segment.get_state_at(target_hash)")
    lines.append("        return None")
    lines.append("")

    # _select_witnesses - full implementation matching network.py logic
    lines.append("    def _select_witnesses(")
    lines.append("        self,")
    lines.append("        seed: bytes,")
    lines.append("        chain_state: dict,")
    lines.append("        count: int = WITNESS_COUNT,")
    lines.append("        exclude: List[str] = None,")
    lines.append("        min_high_trust: int = MIN_HIGH_TRUST_WITNESSES,")
    lines.append("        max_prior_interactions: int = MAX_PRIOR_INTERACTIONS,")
    lines.append("        interaction_with: str = None,")
    lines.append("    ) -> List[str]:")
    lines.append('        """SELECT_WITNESSES: Deterministically select witnesses from seed and chain state."""')
    lines.append("        import random as _random")
    lines.append("        exclude = exclude or []")
    lines.append("        ")
    lines.append("        # Get candidates from chain state")
    lines.append('        known_peers = chain_state.get("known_peers", [])')
    lines.append("        candidates = [p for p in known_peers if p not in exclude]")
    lines.append("        ")
    lines.append("        if not candidates:")
    lines.append("            return []")
    lines.append("        ")
    lines.append("        # Sort deterministically")
    lines.append("        candidates = sorted(candidates)")
    lines.append("        ")
    lines.append("        # Filter by interaction count if available")
    lines.append('        if interaction_with and "interaction_counts" in chain_state:')
    lines.append('            counts = chain_state["interaction_counts"]')
    lines.append("            candidates = [")
    lines.append("                c for c in candidates")
    lines.append("                if counts.get(c, 0) <= max_prior_interactions")
    lines.append("            ]")
    lines.append("        ")
    lines.append("        # Separate by trust level")
    lines.append('        trust_scores = chain_state.get("trust_scores", {})')
    lines.append("        HIGH_TRUST_THRESHOLD = 1.0")
    lines.append("        ")
    lines.append("        high_trust = sorted([c for c in candidates if trust_scores.get(c, 0) >= HIGH_TRUST_THRESHOLD])")
    lines.append("        low_trust = sorted([c for c in candidates if trust_scores.get(c, 0) < HIGH_TRUST_THRESHOLD])")
    lines.append("        ")
    lines.append("        # Seeded selection")
    lines.append("        rng = _random.Random(seed)")
    lines.append("        ")
    lines.append("        selected = []")
    lines.append("        ")
    lines.append("        # Select required high-trust witnesses")
    lines.append("        if high_trust:")
    lines.append("            ht_sample = min(min_high_trust, len(high_trust))")
    lines.append("            selected.extend(rng.sample(high_trust, ht_sample))")
    lines.append("        ")
    lines.append("        # Fill remaining slots from all candidates")
    lines.append("        remaining = [c for c in candidates if c not in selected]")
    lines.append("        needed = count - len(selected)")
    lines.append("        if remaining and needed > 0:")
    lines.append("            selected.extend(rng.sample(remaining, min(needed, len(remaining))))")
    lines.append("        ")
    lines.append("        return selected")
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

    # _remove
    lines.append("    def _remove(self, lst: list, item: Any) -> list:")
    lines.append('        """REMOVE: Remove item from list and return new list."""')
    lines.append("        return [x for x in lst if x != item] if lst else []")
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

    # _compute_consensus (Witness helper)
    lines.append("    def _compute_consensus(self, preliminaries: list) -> str:")
    lines.append('        """COMPUTE_CONSENSUS: Determine consensus from preliminary verdicts."""')
    lines.append("        if not preliminaries:")
    lines.append('            return "REJECT"')
    lines.append("        accept_count = 0")
    lines.append("        reject_count = 0")
    lines.append("        for p in preliminaries:")
    lines.append("            verdict = p.get('verdict') if isinstance(p, dict) else getattr(p, 'verdict', None)")
    lines.append("            if verdict in ('ACCEPT', WitnessVerdict.ACCEPT):")
    lines.append("                accept_count += 1")
    lines.append("            else:")
    lines.append("                reject_count += 1")
    lines.append("        # Need threshold for acceptance")
    lines.append("        if accept_count >= WITNESS_THRESHOLD:")
    lines.append('            return "ACCEPT"')
    lines.append('        return "REJECT"')
    lines.append("")

    # _build_lock_result (Witness helper)
    lines.append("    def _build_lock_result(self) -> Dict[str, Any]:")
    lines.append('        """BUILD_LOCK_RESULT: Build the final lock result structure."""')
    lines.append("        consensus = self.load('consensus_direction')")
    lines.append("        # Use enum for type checking but store name for JSON serialization")
    lines.append("        status_enum = LockStatus.ACCEPTED if consensus == 'ACCEPT' else LockStatus.REJECTED")
    lines.append("        # Extract signatures from collected votes")
    lines.append("        votes = self.load('votes') or []")
    lines.append("        signatures = [v.get('signature') for v in votes if v.get('signature')]")
    lines.append("        return {")
    lines.append('            "session_id": self.load("session_id"),')
    lines.append('            "consumer": self.load("consumer"),')
    lines.append('            "provider": self.load("provider"),')
    lines.append('            "amount": self.load("amount"),')
    lines.append('            "status": status_enum.name,  # Use string for JSON serialization')
    lines.append('            "observed_balance": self.load("observed_balance"),')
    lines.append('            "witnesses": self.load("witnesses"),')
    lines.append('            "witness_signatures": signatures,')
    lines.append('            "timestamp": self.current_time,')
    lines.append("        }")
    lines.append("")

    return "\n".join(lines)


def generate_python(schema_dir: Path, output_path: Path = None) -> str:
    """Generate Python code from schema."""
    schema = load_schema(schema_dir)

    transaction = schema.get("transaction", {})
    tx_name = transaction.get("name", "Unknown")
    tx_id = transaction.get("id", "00")
    tx_desc = transaction.get("description", "")

    lines = ['"""']
    lines.append(f"Transaction {tx_id}: {tx_name}")
    lines.append("")
    lines.append(f"{tx_desc}")
    lines.append("")
    lines.append("GENERATED FROM schema.yaml")
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
    lines.append("        self.state_history.append((self.current_time, self.state))")
    lines.append("        self.state = new_state")
    lines.append("        self.store('state_entered_at', self.current_time)")
    lines.append("")
    lines.append("    def tick(self, current_time: float) -> List[Message]:")
    lines.append("        raise NotImplementedError")
    lines.append("")
    lines.append("")

    # Actor classes
    actors = schema.get("actors", {})
    for actor_name, actor_info in actors.items():
        lines.append("# =============================================================================")
        lines.append(f"# {actor_name}")
        lines.append("# =============================================================================")
        lines.append("")

        generator = PythonActorGenerator(actor_name, actor_info, schema)
        lines.append(generator.generate())
        lines.append("")
        lines.append(generate_actor_helpers(actor_name, actor_info, schema))

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
        description="Generate documentation and Python code from transaction schema"
    )
    parser.add_argument("schema_dir", help="Directory containing schema.yaml")
    parser.add_argument("--markdown", action="store_true", help="Generate markdown documentation")
    parser.add_argument("--python", action="store_true", help="Generate Python code")
    parser.add_argument("--output-dir", help="Output directory")

    args = parser.parse_args()

    schema_dir = Path(args.schema_dir)
    if not schema_dir.exists():
        print(f"Error: Directory not found: {schema_dir}", file=sys.stderr)
        sys.exit(1)

    if args.markdown:
        output_dir = Path(args.output_dir) if args.output_dir else schema_dir.parent
        tx_name = schema_dir.name
        output_path = output_dir / f"{tx_name}.md"
        generate_markdown(schema_dir, output_path)

    if args.python:
        output_dir = Path(args.output_dir) if args.output_dir else Path("simulations/transactions")
        tx_name = schema_dir.name.split("_", 1)[1] if "_" in schema_dir.name else schema_dir.name
        output_path = output_dir / f"{tx_name}_generated.py"
        generate_python(schema_dir, output_path)

    if not args.markdown and not args.python:
        print("Specify --markdown and/or --python to generate output")
        sys.exit(1)


if __name__ == "__main__":
    main()
