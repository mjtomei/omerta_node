"""
AST node definitions for the transaction DSL.
"""

from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any, Union


# =============================================================================
# Top-level declarations
# =============================================================================

@dataclass
class Transaction:
    id: str
    name: str
    line: int = 0
    column: int = 0


@dataclass
class Import:
    path: str
    line: int = 0
    column: int = 0


@dataclass
class Parameter:
    name: str
    value: Union[int, float, str]
    unit: Optional[str] = None
    description: Optional[str] = None
    line: int = 0
    column: int = 0


@dataclass
class EnumValue:
    name: str
    comment: Optional[str] = None
    line: int = 0
    column: int = 0


@dataclass
class EnumDecl:
    name: str
    values: List['EnumValue'] = field(default_factory=list)
    line: int = 0
    column: int = 0


@dataclass
class Field:
    name: str
    type: str  # Type string including generics like "list<peer_id>"
    line: int = 0
    column: int = 0


@dataclass
class MessageDecl:
    name: str
    sender: str
    recipients: List[str]
    signed: bool
    fields: List[Field] = field(default_factory=list)
    line: int = 0
    column: int = 0


@dataclass
class BlockDecl:
    name: str
    appended_by: List[str]
    fields: List[Field] = field(default_factory=list)
    line: int = 0
    column: int = 0


# =============================================================================
# Actor components
# =============================================================================

@dataclass
class TriggerDecl:
    name: str
    params: List[str]  # Just parameter names
    allowed_in: List[str]
    description: Optional[str] = None
    line: int = 0
    column: int = 0


@dataclass
class StateDecl:
    name: str
    initial: bool = False
    terminal: bool = False
    description: Optional[str] = None
    line: int = 0
    column: int = 0


# =============================================================================
# Actions
# =============================================================================

@dataclass
class StoreAction:
    """store x, y, z  OR  store x = expr"""
    fields: List[str] = field(default_factory=list)  # For: store x, y, z
    assignments: Dict[str, str] = field(default_factory=dict)  # For: store x = expr
    line: int = 0
    column: int = 0


@dataclass
class ComputeAction:
    """compute x = expr"""
    name: str
    expression: str
    line: int = 0
    column: int = 0


@dataclass
class SendAction:
    """send MESSAGE to target"""
    message: str
    target: str  # e.g., "consumer", "each(witnesses)", "provider"
    line: int = 0
    column: int = 0


@dataclass
class AppendAction:
    """append list <- value"""
    list_name: str
    value: str
    line: int = 0
    column: int = 0


@dataclass
class AppendBlockAction:
    """append_block BLOCK_TYPE"""
    block_type: str
    line: int = 0
    column: int = 0


Action = Union[StoreAction, ComputeAction, SendAction, AppendAction, AppendBlockAction]


# =============================================================================
# Transitions
# =============================================================================

@dataclass
class Transition:
    from_state: str
    to_state: str
    trigger: Optional[str] = None  # None for 'auto'
    auto: bool = False
    guard: Optional[str] = None
    actions: List[Action] = field(default_factory=list)
    line: int = 0
    column: int = 0


# =============================================================================
# Actor
# =============================================================================

@dataclass
class ActorDecl:
    name: str
    description: Optional[str] = None
    store: List[Field] = field(default_factory=list)
    triggers: List['TriggerDecl'] = field(default_factory=list)
    states: List['StateDecl'] = field(default_factory=list)
    transitions: List['Transition'] = field(default_factory=list)
    line: int = 0
    column: int = 0


# =============================================================================
# Functions
# =============================================================================

@dataclass
class FunctionParam:
    name: str
    type: str
    line: int = 0
    column: int = 0


@dataclass
class FunctionDecl:
    name: str
    params: List[FunctionParam] = field(default_factory=list)
    return_type: str = "void"
    body: str = ""  # Raw body text for now
    line: int = 0
    column: int = 0


# =============================================================================
# Schema (root node)
# =============================================================================

@dataclass
class Schema:
    transaction: Optional[Transaction] = None
    imports: List[Import] = field(default_factory=list)
    parameters: List[Parameter] = field(default_factory=list)
    enums: List[EnumDecl] = field(default_factory=list)
    messages: List[MessageDecl] = field(default_factory=list)
    blocks: List[BlockDecl] = field(default_factory=list)
    actors: List[ActorDecl] = field(default_factory=list)
    functions: List[FunctionDecl] = field(default_factory=list)
    line: int = 0
    column: int = 0
