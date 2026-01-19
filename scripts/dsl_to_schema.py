"""
Convert DSL AST to schema dict format (compatible with existing generator).
"""

from typing import Dict, Any, List

try:
    from .dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, StateDecl,
        Transition, StoreAction, ComputeAction, SendAction, AppendAction,
        AppendBlockAction, FunctionDecl, FunctionParam, Action
    )
except ImportError:
    from dsl_ast import (
    Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
    Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, StateDecl,
    Transition, StoreAction, ComputeAction, SendAction, AppendAction,
    AppendBlockAction, FunctionDecl, FunctionParam, Action
)


def ast_to_schema(ast: Schema) -> Dict[str, Any]:
    """Convert a Schema AST to the dict format used by the generator."""
    schema = {}

    # Transaction info
    if ast.transaction:
        schema['transaction'] = {
            'id': ast.transaction.id,
            'name': ast.transaction.name,
        }

    # Imports
    if ast.imports:
        schema['imports'] = [imp.path for imp in ast.imports]

    # Parameters
    if ast.parameters:
        schema['parameters'] = {}
        for param in ast.parameters:
            param_dict = {'value': param.value}
            if param.unit:
                param_dict['unit'] = param.unit
            if param.description:
                param_dict['description'] = param.description
            schema['parameters'][param.name] = param_dict

    # Enums
    if ast.enums:
        schema['enums'] = {}
        for enum in ast.enums:
            values = []
            for val in enum.values:
                if val.comment:
                    values.append(f"{val.name}  # {val.comment}")
                else:
                    values.append(val.name)
            schema['enums'][enum.name] = {
                'values': [v.name for v in enum.values]
            }

    # Messages
    if ast.messages:
        schema['messages'] = {}
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

            schema['messages'][msg.name] = msg_dict

    # Blocks
    if ast.blocks:
        schema['blocks'] = {}
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

            schema['blocks'][block.name] = block_dict

    # Actors
    if ast.actors:
        schema['actors'] = {}
        for actor in ast.actors:
            schema['actors'][actor.name] = convert_actor(actor)

    # Functions
    if ast.functions:
        schema['functions'] = {}
        for func in ast.functions:
            func_dict = {
                'params': [{p.name: convert_type(p.type)} for p in func.params],
                'returns': convert_type(func.return_type),
                'body': func.body,
            }
            schema['functions'][func.name] = func_dict

    return schema


def convert_type(type_str: str) -> str:
    """Convert DSL type syntax to YAML schema type syntax."""
    # Convert angle brackets to square brackets for generics
    # list<peer_id> -> list[peer_id]
    # map<string, int> -> map[string, int]
    return type_str.replace('<', '[').replace('>', ']')


def convert_actor(actor: ActorDecl) -> Dict[str, Any]:
    """Convert an ActorDecl to schema dict format."""
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
                'params': {p: 'any' for p in trigger.params},  # Type info not in DSL
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
    """Convert a Transition to schema dict format."""
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

    # Actions
    if trans.actions:
        trans_dict['actions'] = []
        for action in trans.actions:
            trans_dict['actions'].append(convert_action(action))

    return trans_dict


def convert_action(action: Action) -> Dict[str, Any]:
    """Convert an Action to schema dict format."""
    if isinstance(action, StoreAction):
        if action.assignments:
            # store x = expr
            return {'store': action.assignments}
        else:
            # store x, y, z
            return {'store': action.fields}

    elif isinstance(action, ComputeAction):
        return {
            'compute': action.name,
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


def convert_schema_file(dsl_source: str) -> Dict[str, Any]:
    """Parse DSL source and convert to schema dict."""
    try:
        from .dsl_parser import parse
    except ImportError:
        from dsl_parser import parse
    ast = parse(dsl_source)
    return ast_to_schema(ast)
