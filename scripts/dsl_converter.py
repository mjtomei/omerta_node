"""
DSL converter utilities.

Provides:
- load_transaction_ast(): Load DSL file with imports, return merged Schema AST
- ast_to_dict(): Convert Schema AST to dict format (legacy compatibility)
"""

from typing import Dict, Any, List
from pathlib import Path

try:
    from .dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, TriggerParam, StateDecl,
        Transition, OnGuardFail, StoreAction, ComputeAction, LookupAction, SendAction,
        AppendAction, AppendBlockAction, FunctionDecl, FunctionParam, Action
    )
    from .dsl_parser import parse
except ImportError:
    from dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, TriggerParam, StateDecl,
        Transition, OnGuardFail, StoreAction, ComputeAction, LookupAction, SendAction,
        AppendAction, AppendBlockAction, FunctionDecl, FunctionParam, Action
    )
    from dsl_parser import parse


# =============================================================================
# AST Loading (returns Schema directly)
# =============================================================================

def load_transaction_ast(tx_path, base_dir=None) -> Schema:
    """
    Load a DSL transaction file with import resolution.

    Args:
        tx_path: Path to the .omt file
        base_dir: Base directory for resolving imports (defaults to docs/protocol/)

    Returns:
        Merged Schema AST with all imports resolved
    """
    tx_path = Path(tx_path)
    if base_dir is None:
        # Default base dir is docs/protocol/ relative to the transaction file
        base_dir = tx_path.parent
        while base_dir.name != 'protocol' and base_dir.parent != base_dir:
            base_dir = base_dir.parent
        if base_dir.name != 'protocol':
            base_dir = tx_path.parent
    else:
        base_dir = Path(base_dir)

    loaded = set()
    return _load_ast_with_imports(tx_path, base_dir, loaded)


def _load_ast_with_imports(tx_path: Path, base_dir: Path, loaded: set) -> Schema:
    """Load transaction file and recursively resolve imports at AST level."""
    tx_path = Path(tx_path).resolve()
    if str(tx_path) in loaded:
        return Schema()  # Already loaded (circular import protection)
    loaded.add(str(tx_path))

    # Read and parse the transaction
    source = tx_path.read_text()
    ast = parse(source)

    # Start with empty merged schema
    merged = Schema()

    # First, resolve all imports
    for imp in ast.imports:
        import_path = base_dir / f"{imp.path}.omt"
        if not import_path.exists():
            import_path = base_dir / imp.path
            if not import_path.exists():
                raise FileNotFoundError(f"Import not found: {imp.path} (tried {import_path})")

        imported = _load_ast_with_imports(import_path, base_dir, loaded)
        _merge_schemas(merged, imported)

    # Merge our own AST on top
    _merge_schemas(merged, ast)

    return merged


def _merge_schemas(target: Schema, source: Schema):
    """Merge source Schema into target Schema."""
    # Transaction - source overwrites
    if source.transaction:
        target.transaction = source.transaction

    # Lists - extend with source items (avoid duplicates by name)
    def merge_by_name(target_list, source_list, get_name):
        existing = {get_name(item) for item in target_list}
        for item in source_list:
            if get_name(item) not in existing:
                target_list.append(item)
                existing.add(get_name(item))

    merge_by_name(target.parameters, source.parameters, lambda p: p.name)
    merge_by_name(target.enums, source.enums, lambda e: e.name)
    merge_by_name(target.messages, source.messages, lambda m: m.name)
    merge_by_name(target.blocks, source.blocks, lambda b: b.name)
    merge_by_name(target.actors, source.actors, lambda a: a.name)
    merge_by_name(target.functions, source.functions, lambda f: f.name)

    # Imports - just extend
    target.imports.extend(source.imports)


# =============================================================================
# Dict conversion (legacy compatibility)
# =============================================================================


def ast_to_dict(ast: Schema) -> Dict[str, Any]:
    """Convert a transaction AST to the dict format used by the generator."""
    result = {}

    # Transaction info
    if ast.transaction:
        result['transaction'] = {
            'id': ast.transaction.id,
            'name': ast.transaction.name,
        }
        if ast.transaction.description:
            result['transaction']['description'] = ast.transaction.description

    # Imports
    if ast.imports:
        result['imports'] = [imp.path for imp in ast.imports]

    # Parameters
    if ast.parameters:
        result['parameters'] = {}
        for param in ast.parameters:
            param_dict = {'value': param.value}
            if param.unit:
                param_dict['unit'] = param.unit
            if param.description:
                param_dict['description'] = param.description
            result['parameters'][param.name] = param_dict

    # Enums
    if ast.enums:
        result['enums'] = {}
        for enum in ast.enums:
            enum_dict = {
                'values': [v.name for v in enum.values]
            }
            if enum.description:
                enum_dict['description'] = enum.description
            result['enums'][enum.name] = enum_dict

    # Messages
    if ast.messages:
        result['messages'] = {}
        for msg in ast.messages:
            msg_dict = {
                'sender': msg.sender,
                'recipients': msg.recipients,
                'fields': {},
            }
            if msg.signed:
                msg_dict['signed_by'] = msg.sender.lower()

            for field in msg.fields:
                msg_dict['fields'][field.name] = {
                    'type': convert_type(field.type),
                    'required': True,
                }

            result['messages'][msg.name] = msg_dict

    # Blocks
    if ast.blocks:
        result['blocks'] = {}
        for block in ast.blocks:
            block_dict = {
                'appended_by': block.appended_by,
                'fields': {},
            }

            for field in block.fields:
                block_dict['fields'][field.name] = {
                    'type': convert_type(field.type),
                    'required': True,
                }

            result['blocks'][block.name] = block_dict

    # Actors
    if ast.actors:
        result['actors'] = {}
        for actor in ast.actors:
            result['actors'][actor.name] = convert_actor(actor)

    # Functions
    if ast.functions:
        result['functions'] = {}
        for func in ast.functions:
            func_dict = {
                'params': [{p.name: convert_type(p.type)} for p in func.params],
                'returns': convert_type(func.return_type),
                'body': func.body,
            }
            result['functions'][func.name] = func_dict

    return result


def _expr_to_string(expr) -> str:
    """Convert an Expr AST node to string representation.

    This is used when the dict format expects string expressions.
    """
    try:
        from .dsl_ast import (
            Identifier, Literal, BinaryExpr, UnaryExpr, IfExpr,
            FunctionCallExpr, FieldAccessExpr, DynamicFieldAccessExpr, IndexAccessExpr,
            LambdaExpr, StructLiteralExpr, ListLiteralExpr, EnumRefExpr,
            BinaryOperator, UnaryOperator
        )
    except ImportError:
        from dsl_ast import (
            Identifier, Literal, BinaryExpr, UnaryExpr, IfExpr,
            FunctionCallExpr, FieldAccessExpr, DynamicFieldAccessExpr, IndexAccessExpr,
            LambdaExpr, StructLiteralExpr, ListLiteralExpr, EnumRefExpr,
            BinaryOperator, UnaryOperator
        )

    if isinstance(expr, str):
        return expr
    elif isinstance(expr, Identifier):
        return expr.name
    elif isinstance(expr, Literal):
        if expr.type == "string":
            return f'"{expr.value}"'
        elif expr.type == "null":
            return "null"
        elif expr.type == "bool":
            return "true" if expr.value else "false"
        else:
            return str(expr.value)
    elif isinstance(expr, BinaryExpr):
        op_map = {
            BinaryOperator.ADD: '+', BinaryOperator.SUB: '-',
            BinaryOperator.MUL: '*', BinaryOperator.DIV: '/',
            BinaryOperator.EQ: '==', BinaryOperator.NEQ: '!=',
            BinaryOperator.LT: '<', BinaryOperator.GT: '>',
            BinaryOperator.LTE: '<=', BinaryOperator.GTE: '>=',
            BinaryOperator.AND: 'and', BinaryOperator.OR: 'or',
        }
        op_str = op_map.get(expr.op, str(expr.op))
        return f"{_expr_to_string(expr.left)} {op_str} {_expr_to_string(expr.right)}"
    elif isinstance(expr, UnaryExpr):
        op_map = {UnaryOperator.NOT: 'not ', UnaryOperator.NEG: '-'}
        op_str = op_map.get(expr.op, str(expr.op))
        return f"{op_str}{_expr_to_string(expr.operand)}"
    elif isinstance(expr, FunctionCallExpr):
        args = ', '.join(_expr_to_string(arg) for arg in expr.args)
        return f"{expr.name}({args})"
    elif isinstance(expr, FieldAccessExpr):
        return f"{_expr_to_string(expr.object)}.{expr.field}"
    elif isinstance(expr, EnumRefExpr):
        return f"{expr.enum_name}.{expr.value}"
    elif isinstance(expr, LambdaExpr):
        return f"{expr.param} => {_expr_to_string(expr.body)}"
    elif isinstance(expr, IfExpr):
        return f"IF {_expr_to_string(expr.condition)} THEN {_expr_to_string(expr.then_expr)} ELSE {_expr_to_string(expr.else_expr)}"
    elif isinstance(expr, StructLiteralExpr):
        fields = ', '.join(f"{k} = {_expr_to_string(v)}" for k, v in expr.fields.items())
        return f"({fields})"
    elif isinstance(expr, ListLiteralExpr):
        elements = ', '.join(_expr_to_string(e) for e in expr.elements)
        return f"[{elements}]"
    elif isinstance(expr, IndexAccessExpr):
        return f"{_expr_to_string(expr.object)}[{_expr_to_string(expr.index)}]"
    elif isinstance(expr, DynamicFieldAccessExpr):
        return f"{_expr_to_string(expr.object)}.{{{_expr_to_string(expr.key_expr)}}}"
    else:
        return str(expr)


def convert_type(type_expr) -> str:
    """Convert DSL type (string or TypeExpr AST) to generator type syntax.

    Handles both legacy string types and new TypeExpr AST nodes.
    """
    # Import TypeExpr types here to avoid circular imports
    try:
        from .dsl_ast import SimpleType, ListType, MapType
    except ImportError:
        from dsl_ast import SimpleType, ListType, MapType

    # Handle TypeExpr AST nodes
    if isinstance(type_expr, SimpleType):
        return type_expr.name
    elif isinstance(type_expr, ListType):
        return f"list[{convert_type(type_expr.element_type)}]"
    elif isinstance(type_expr, MapType):
        return f"map[{convert_type(type_expr.key_type)}, {convert_type(type_expr.value_type)}]"
    elif isinstance(type_expr, str):
        # Legacy string format - convert angle brackets to square brackets
        return type_expr.replace('<', '[').replace('>', ']')
    else:
        # Fallback for unknown types
        return str(type_expr)


def convert_actor(actor: ActorDecl) -> Dict[str, Any]:
    """Convert an ActorDecl to dict format."""
    actor_dict = {}

    if actor.description:
        actor_dict['description'] = actor.description

    # Store schema
    if actor.store:
        actor_dict['store_schema'] = {}
        for field in actor.store:
            actor_dict['store_schema'][field.name] = convert_type(field.type)

    # External triggers
    if actor.triggers:
        actor_dict['external_triggers'] = {}
        for trigger in actor.triggers:
            trigger_dict = {
                'params': {p.name: convert_type(p.type) for p in trigger.params},
                'allowed_in': trigger.allowed_in,
            }
            if trigger.description:
                trigger_dict['description'] = trigger.description
            actor_dict['external_triggers'][trigger.name] = trigger_dict

    # Initial state
    for state in actor.states:
        if state.initial:
            actor_dict['initial_state'] = state.name
            break

    # States
    if actor.states:
        actor_dict['states'] = {}
        for state in actor.states:
            state_dict = {}
            if state.description:
                state_dict['description'] = state.description
            if state.terminal:
                state_dict['terminal'] = True
            actor_dict['states'][state.name] = state_dict

    # Transitions
    if actor.transitions:
        actor_dict['transitions'] = []
        for trans in actor.transitions:
            actor_dict['transitions'].append(convert_transition(trans))

    # Guards (empty dict for compatibility)
    actor_dict['guards'] = {}

    return actor_dict


def convert_transition(trans: Transition) -> Dict[str, Any]:
    """Convert a Transition to dict format."""
    # Import TriggerExpr types here to avoid circular imports
    try:
        from .dsl_ast import MessageTrigger, TimeoutTrigger, NamedTrigger
    except ImportError:
        from dsl_ast import MessageTrigger, TimeoutTrigger, NamedTrigger

    trans_dict = {
        'from': trans.from_state,
        'to': trans.to_state,
    }

    # Trigger - handle both string (legacy) and TriggerExpr AST nodes
    trigger_str = None
    is_message_trigger = False

    if trans.auto:
        trans_dict['trigger'] = 'auto'
    elif trans.trigger:
        if isinstance(trans.trigger, str):
            # Legacy string format
            trigger_str = trans.trigger
            is_message_trigger = (
                trigger_str.isupper() and
                not trigger_str.startswith('timeout(')
            )
        elif isinstance(trans.trigger, MessageTrigger):
            trigger_str = trans.trigger.message_type
            is_message_trigger = True
        elif isinstance(trans.trigger, TimeoutTrigger):
            trigger_str = f"timeout({trans.trigger.parameter})"
        elif isinstance(trans.trigger, NamedTrigger):
            trigger_str = trans.trigger.name
            # Named triggers (external) are lowercase, message triggers are uppercase
            is_message_trigger = trigger_str.isupper()
        else:
            trigger_str = str(trans.trigger)

        trans_dict['trigger'] = trigger_str

    # Guard - handle both string (legacy) and Expr AST nodes
    if trans.guard:
        if isinstance(trans.guard, str):
            trans_dict['guard'] = trans.guard
        else:
            # Convert Expr AST to string representation
            trans_dict['guard'] = _expr_to_string(trans.guard)

    # Actions
    if trans.actions:
        trans_dict['actions'] = []
        for action in trans.actions:
            trans_dict['actions'].append(convert_action(action, is_message_trigger))

    # On guard fail
    if trans.on_guard_fail:
        fail_dict = {
            'target': trans.on_guard_fail.target,
        }
        if trans.on_guard_fail.actions:
            fail_dict['actions'] = []
            for action in trans.on_guard_fail.actions:
                fail_dict['actions'].append(convert_action(action, is_message_trigger))
        trans_dict['on_guard_fail'] = fail_dict

    return trans_dict


def _strip_outer_quotes(value: str) -> str:
    """Strip outer double quotes from a string value if present."""
    if isinstance(value, str) and len(value) >= 2:
        if (value.startswith('"') and value.endswith('"')) or \
           (value.startswith("'") and value.endswith("'")):
            return value[1:-1]
    return value


def _is_message_field_access(expr) -> bool:
    """Check if expr is a message field access (message.xxx or message.payload.xxx)."""
    try:
        from .dsl_ast import FieldAccessExpr, Identifier
    except ImportError:
        from dsl_ast import FieldAccessExpr, Identifier

    if isinstance(expr, str):
        return expr.startswith('message.') or expr.startswith('message .')

    if isinstance(expr, FieldAccessExpr):
        # Check for message.xxx
        if isinstance(expr.object, Identifier) and expr.object.name == 'message':
            return True
        # Check for message.payload.xxx
        if isinstance(expr.object, FieldAccessExpr):
            return _is_message_field_access(expr.object)
    return False


def _extract_message_field(expr) -> str:
    """Extract the field name from a message field access expression."""
    try:
        from .dsl_ast import FieldAccessExpr, Identifier
    except ImportError:
        from dsl_ast import FieldAccessExpr, Identifier

    if isinstance(expr, str):
        return expr.split('.', 1)[1].strip()

    if isinstance(expr, FieldAccessExpr):
        if isinstance(expr.object, Identifier) and expr.object.name == 'message':
            # message.field -> field
            return expr.field
        elif isinstance(expr.object, FieldAccessExpr):
            # message.payload.field -> payload.field
            parent = _extract_message_field(expr.object)
            return f"{parent}.{expr.field}"
    return _expr_to_string(expr)


def convert_action(action: Action, is_message_trigger: bool = False) -> Dict[str, Any]:
    """Convert an Action to dict format."""
    if isinstance(action, StoreAction):
        if action.assignments:
            # Check if any assignments are message field access (store_from_message)
            from_message = {}
            regular = {}
            for key, value in action.assignments.items():
                if _is_message_field_access(value):
                    # store_from_message: { local_field: message_field }
                    msg_field = _extract_message_field(value)
                    from_message[key] = msg_field
                else:
                    # Convert Expr to string if needed and strip outer quotes
                    value_str = _expr_to_string(value) if not isinstance(value, str) else value
                    regular[key] = _strip_outer_quotes(value_str)

            if from_message and not regular:
                return {'store_from_message': from_message}
            elif from_message:
                # Mixed - shouldn't happen in practice, but handle gracefully
                return {'store_from_message': from_message, 'store': regular}
            else:
                return {'store': regular}
        else:
            # store x, y, z - context determines interpretation
            if is_message_trigger:
                # Message-triggered transition: fields come from message payload
                return {'store_from_message': action.fields}
            else:
                # External trigger: fields are function parameters
                return {'store': action.fields}

    elif isinstance(action, ComputeAction):
        expr_str = _expr_to_string(action.expression) if not isinstance(action.expression, str) else action.expression
        return {
            'compute': action.name,
            'from': expr_str,
        }

    elif isinstance(action, LookupAction):
        expr_str = _expr_to_string(action.expression) if not isinstance(action.expression, str) else action.expression
        return {
            'lookup': action.name,
            'from': expr_str,
        }

    elif isinstance(action, SendAction):
        target_str = _expr_to_string(action.target) if not isinstance(action.target, str) else action.target
        return {
            'send': {
                'message': action.message,
                'to': target_str,
            }
        }

    elif isinstance(action, AppendAction):
        value_str = _expr_to_string(action.value) if not isinstance(action.value, str) else action.value
        return {
            'append': {
                action.list_name: value_str,
            }
        }

    elif isinstance(action, AppendBlockAction):
        return {
            'append_block': {
                'type': action.block_type,
            }
        }

    return {}


def convert_dsl_source(dsl_source: str) -> Dict[str, Any]:
    """Parse DSL source and convert to dict format."""
    ast = parse(dsl_source)
    return ast_to_dict(ast)


def load_transaction(tx_path, base_dir=None) -> Dict[str, Any]:
    """
    Load a DSL transaction file with import resolution.

    Args:
        tx_path: Path to the .omt file
        base_dir: Base directory for resolving imports (defaults to docs/protocol/)

    Returns:
        Merged transaction dict with all imports resolved

    Note: This is a legacy function that returns a dict. Prefer load_transaction_ast()
    for new code that works directly with the AST.
    """
    ast = load_transaction_ast(tx_path, base_dir)
    return ast_to_dict(ast)


# Backward compatibility aliases
ast_to_schema = ast_to_dict
load_dsl_schema = load_transaction
convert_schema_file = convert_dsl_source
