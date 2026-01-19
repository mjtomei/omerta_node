"""
Convert DSL AST to dict format (compatible with existing generator).
"""

from typing import Dict, Any, List

try:
    from .dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, TriggerParam, StateDecl,
        Transition, OnGuardFail, StoreAction, ComputeAction, LookupAction, SendAction,
        AppendAction, AppendBlockAction, FunctionDecl, FunctionParam, Action
    )
except ImportError:
    from dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, TriggerParam, StateDecl,
        Transition, OnGuardFail, StoreAction, ComputeAction, LookupAction, SendAction,
        AppendAction, AppendBlockAction, FunctionDecl, FunctionParam, Action
    )


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


def convert_type(type_str: str) -> str:
    """Convert DSL type syntax to generator type syntax."""
    # Convert angle brackets to square brackets for generics
    # list<peer_id> -> list[peer_id]
    # map<string, int> -> map[string, int]
    return type_str.replace('<', '[').replace('>', ']')


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
    trans_dict = {
        'from': trans.from_state,
        'to': trans.to_state,
    }

    # Trigger
    if trans.auto:
        trans_dict['trigger'] = 'auto'
    elif trans.trigger:
        trans_dict['trigger'] = trans.trigger

    # Guard
    if trans.guard:
        trans_dict['guard'] = trans.guard

    # Determine if this is a message-triggered transition
    # Message names are ALL_CAPS, external triggers are lowercase
    is_message_trigger = (
        trans.trigger is not None and
        not trans.auto and
        trans.trigger.isupper() and
        not trans.trigger.startswith('timeout(')
    )

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


def convert_action(action: Action, is_message_trigger: bool = False) -> Dict[str, Any]:
    """Convert an Action to dict format."""
    if isinstance(action, StoreAction):
        if action.assignments:
            # Check if any assignments are message field access (store_from_message)
            from_message = {}
            regular = {}
            for key, value in action.assignments.items():
                if value.startswith('message.') or value.startswith('message .'):
                    # store_from_message: { local_field: message_field }
                    # Extract the field name after 'message.'
                    msg_field = value.split('.', 1)[1].strip()
                    from_message[key] = msg_field
                else:
                    # Strip outer quotes from string literals
                    regular[key] = _strip_outer_quotes(value)

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
        return {
            'compute': action.name,
            'from': action.expression,
        }

    elif isinstance(action, LookupAction):
        return {
            'lookup': action.name,
            'from': action.expression,
        }

    elif isinstance(action, SendAction):
        return {
            'send': {
                'message': action.message,
                'to': action.target,
            }
        }

    elif isinstance(action, AppendAction):
        return {
            'append': {
                action.list_name: action.value,
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
    try:
        from .dsl_parser import parse
    except ImportError:
        from dsl_parser import parse
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
    """
    from pathlib import Path
    try:
        from .dsl_parser import parse
    except ImportError:
        from dsl_parser import parse

    tx_path = Path(tx_path)
    if base_dir is None:
        # Default base dir is docs/protocol/ relative to the transaction file
        # Walk up from tx_path to find docs/protocol
        base_dir = tx_path.parent
        while base_dir.name != 'protocol' and base_dir.parent != base_dir:
            base_dir = base_dir.parent
        if base_dir.name == 'protocol':
            base_dir = base_dir
        else:
            # Fallback: use transaction file's parent as base
            base_dir = tx_path.parent
    else:
        base_dir = Path(base_dir)

    # Track loaded files to prevent circular imports
    loaded = set()
    return _load_transaction_with_imports(tx_path, base_dir, loaded)


def _load_transaction_with_imports(tx_path, base_dir, loaded: set) -> Dict[str, Any]:
    """Load transaction file and recursively resolve imports."""
    from pathlib import Path
    try:
        from .dsl_parser import parse
    except ImportError:
        from dsl_parser import parse

    tx_path = Path(tx_path).resolve()
    if str(tx_path) in loaded:
        return {}  # Already loaded (circular import protection)
    loaded.add(str(tx_path))

    # Read and parse the transaction
    source = tx_path.read_text()
    ast = parse(source)

    # First, resolve all imports
    merged = {}
    for imp in ast.imports:
        # Try .omt extension first, then without
        import_path = base_dir / f"{imp.path}.omt"
        if not import_path.exists():
            import_path = base_dir / imp.path
            if not import_path.exists():
                raise FileNotFoundError(f"Import not found: {imp.path} (tried {import_path})")

        imported = _load_transaction_with_imports(import_path, base_dir, loaded)
        _merge_dicts(merged, imported)

    # Convert our own definition and merge on top
    own_def = ast_to_dict(ast)
    _merge_dicts(merged, own_def)

    return merged


def _merge_dicts(target: Dict[str, Any], source: Dict[str, Any]):
    """Merge source dict into target dict."""
    # Simple fields - source overwrites
    for key in ['transaction']:
        if key in source:
            target[key] = source[key]

    # Merge dicts (parameters, enums, messages, blocks, actors, functions)
    for key in ['parameters', 'enums', 'messages', 'blocks', 'actors', 'functions', 'types']:
        if key in source:
            if key not in target:
                target[key] = {}
            target[key].update(source[key])

    # Lists (imports) - just append
    for key in ['imports']:
        if key in source:
            if key not in target:
                target[key] = []
            target[key].extend(source[key])


# Backward compatibility aliases
ast_to_schema = ast_to_dict
load_dsl_schema = load_transaction
convert_schema_file = convert_dsl_source
