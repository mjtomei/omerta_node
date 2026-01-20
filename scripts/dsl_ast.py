"""
AST node definitions for the transaction DSL.
"""

from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any, Union
from enum import Enum, auto


# =============================================================================
# Expression AST nodes
# =============================================================================

class BinaryOperator(Enum):
    """Binary operators."""
    # Arithmetic
    ADD = auto()       # +
    SUB = auto()       # -
    MUL = auto()       # *
    DIV = auto()       # /
    # Comparison
    EQ = auto()        # ==
    NEQ = auto()       # !=
    LT = auto()        # <
    GT = auto()        # >
    LTE = auto()       # <=
    GTE = auto()       # >=
    # Boolean
    AND = auto()       # and
    OR = auto()        # or


class UnaryOperator(Enum):
    """Unary operators."""
    NOT = auto()       # not
    NEG = auto()       # - (unary minus)


@dataclass
class Identifier:
    """Variable or name reference."""
    name: str
    line: int = 0
    column: int = 0


@dataclass
class Literal:
    """Literal value (string, number, bool, null)."""
    value: Any
    type: str  # "string", "number", "bool", "null"
    line: int = 0
    column: int = 0


@dataclass
class BinaryExpr:
    """Binary operation: left op right."""
    left: 'Expr'
    op: BinaryOperator
    right: 'Expr'
    line: int = 0
    column: int = 0


@dataclass
class UnaryExpr:
    """Unary operation: op operand."""
    op: UnaryOperator
    operand: 'Expr'
    line: int = 0
    column: int = 0


@dataclass
class IfExpr:
    """Conditional expression: IF cond THEN then_expr ELSE else_expr."""
    condition: 'Expr'
    then_expr: 'Expr'
    else_expr: 'Expr'
    line: int = 0
    column: int = 0


@dataclass
class FunctionCallExpr:
    """Function call: func(arg1, arg2, ...)."""
    name: str
    args: List['Expr'] = field(default_factory=list)
    line: int = 0
    column: int = 0


@dataclass
class FieldAccessExpr:
    """Field access: object.field."""
    object: 'Expr'
    field: str
    line: int = 0
    column: int = 0


@dataclass
class DynamicFieldAccessExpr:
    """Dynamic field access: object.{key_expr}."""
    object: 'Expr'
    key_expr: 'Expr'
    line: int = 0
    column: int = 0


@dataclass
class IndexAccessExpr:
    """Index access: object[index]."""
    object: 'Expr'
    index: 'Expr'
    line: int = 0
    column: int = 0


@dataclass
class LambdaExpr:
    """Lambda expression: param => body."""
    param: str
    body: 'Expr'
    line: int = 0
    column: int = 0


@dataclass
class StructLiteralExpr:
    """Struct literal: { field: value, ... } with optional spread."""
    fields: Dict[str, 'Expr'] = field(default_factory=dict)
    spread: Optional['Expr'] = None  # For { ...base, field: value }
    line: int = 0
    column: int = 0


@dataclass
class ListLiteralExpr:
    """List literal: [a, b, c]."""
    elements: List['Expr'] = field(default_factory=list)
    line: int = 0
    column: int = 0


@dataclass
class EnumRefExpr:
    """Enum reference: EnumName.VALUE."""
    enum_name: str
    value: str
    line: int = 0
    column: int = 0


# Union type for all expressions
Expr = Union[
    Identifier, Literal, BinaryExpr, UnaryExpr, IfExpr,
    FunctionCallExpr, FieldAccessExpr, DynamicFieldAccessExpr, IndexAccessExpr,
    LambdaExpr, StructLiteralExpr, ListLiteralExpr, EnumRefExpr
]


# =============================================================================
# Type AST nodes
# =============================================================================

@dataclass
class SimpleType:
    """Simple type: peer_id, uint, string, hash, etc."""
    name: str
    line: int = 0
    column: int = 0


@dataclass
class ListType:
    """List type: list<element_type>."""
    element_type: 'TypeExpr'
    line: int = 0
    column: int = 0


@dataclass
class MapType:
    """Map type: map<key_type, value_type>."""
    key_type: 'TypeExpr'
    value_type: 'TypeExpr'
    line: int = 0
    column: int = 0


# Union type for all types
TypeExpr = Union[SimpleType, ListType, MapType]


# =============================================================================
# Trigger AST nodes
# =============================================================================

@dataclass
class MessageTrigger:
    """Trigger on message receipt: on MESSAGE_NAME."""
    message_type: str
    line: int = 0
    column: int = 0


@dataclass
class TimeoutTrigger:
    """Trigger on timeout: on timeout(PARAM)."""
    parameter: str
    line: int = 0
    column: int = 0


@dataclass
class NamedTrigger:
    """Trigger on named external trigger: on trigger_name."""
    name: str
    line: int = 0
    column: int = 0


# Union type for all triggers
TriggerExpr = Union[MessageTrigger, TimeoutTrigger, NamedTrigger]


# =============================================================================
# Top-level declarations
# =============================================================================

@dataclass
class Transaction:
    id: str
    name: str
    description: Optional[str] = None
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
    description: Optional[str] = None
    values: List['EnumValue'] = field(default_factory=list)
    line: int = 0
    column: int = 0


@dataclass
class Field:
    name: str
    type: Union[str, 'TypeExpr']  # Type (string for legacy, TypeExpr for new parser)
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
class TriggerParam:
    """Typed trigger parameter."""
    name: str
    type: Union[str, 'TypeExpr']  # Type (string for legacy, TypeExpr for new parser)
    line: int = 0
    column: int = 0


@dataclass
class TriggerDecl:
    name: str
    params: List['TriggerParam']  # Typed parameter list
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
    assignments: Dict[str, Union[str, 'Expr']] = field(default_factory=dict)  # For: STORE(key, value)
    line: int = 0
    column: int = 0


@dataclass
class ComputeAction:
    """compute x = expr"""
    name: str
    expression: Union[str, 'Expr']  # Expression (string for legacy, Expr for new parser)
    line: int = 0
    column: int = 0


@dataclass
class LookupAction:
    """lookup x = expr (lookup value from chain)"""
    name: str
    expression: Union[str, 'Expr']  # Expression (string for legacy, Expr for new parser)
    line: int = 0
    column: int = 0


@dataclass
class SendAction:
    """SEND(target, MESSAGE)"""
    message: str
    target: Union[str, 'Expr']  # Target expression (string for legacy, Expr for new parser)
    line: int = 0
    column: int = 0


@dataclass
class BroadcastAction:
    """BROADCAST(list, MESSAGE)"""
    message: str
    target_list: Union[str, 'Expr']  # Target list expression
    line: int = 0
    column: int = 0


@dataclass
class AppendAction:
    """append list <- value"""
    list_name: str
    value: Union[str, 'Expr']  # Value expression
    line: int = 0
    column: int = 0


@dataclass
class AppendBlockAction:
    """append_block BLOCK_TYPE"""
    block_type: str
    line: int = 0
    column: int = 0


Action = Union[StoreAction, ComputeAction, LookupAction, SendAction, BroadcastAction, AppendAction, AppendBlockAction]


# =============================================================================
# Transitions
# =============================================================================

@dataclass
class OnGuardFail:
    """What to do when a guard fails."""
    target: str  # Target state
    actions: List[Action] = field(default_factory=list)
    line: int = 0
    column: int = 0


@dataclass
class Transition:
    from_state: str
    to_state: str
    trigger: Optional[Union[str, 'TriggerExpr']] = None  # None for 'auto', TriggerExpr for new parser
    auto: bool = False
    guard: Optional[Union[str, 'Expr']] = None  # Guard expression
    actions: List[Action] = field(default_factory=list)
    on_guard_fail: Optional[OnGuardFail] = None
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
    type: Union[str, 'TypeExpr']  # Type (string for legacy, TypeExpr for new parser)
    line: int = 0
    column: int = 0


# =============================================================================
# Function body statements
# =============================================================================

@dataclass
class AssignmentStmt:
    """Assignment statement: name = expression or name[index] = expression"""
    name: str
    expression: Union[str, 'Expr']  # Expression (string for legacy, Expr for new parser)
    index: Optional['Expr'] = None  # Index for indexed assignment (e.g., result[key] = value)
    line: int = 0
    column: int = 0


@dataclass
class ReturnStmt:
    """Return statement: RETURN expression"""
    expression: Union[str, 'Expr']  # Expression (string for legacy, Expr for new parser)
    line: int = 0
    column: int = 0


@dataclass
class ForStmt:
    """For loop: FOR var IN iterable: body"""
    var_name: str
    iterable: Union[str, 'Expr']  # Iterable expression
    body: List['FunctionStatement'] = field(default_factory=list)
    line: int = 0
    column: int = 0


@dataclass
class IfStmt:
    """If statement: IF condition THEN body ELSE else_body"""
    condition: Union[str, 'Expr']  # Condition expression
    then_body: List['FunctionStatement'] = field(default_factory=list)
    else_body: List['FunctionStatement'] = field(default_factory=list)
    line: int = 0
    column: int = 0


# Union type for function body statements
FunctionStatement = Union[AssignmentStmt, ReturnStmt, ForStmt, IfStmt]


@dataclass
class FunctionDecl:
    name: str
    params: List[FunctionParam] = field(default_factory=list)
    return_type: Union[str, 'TypeExpr'] = "void"  # Return type
    body: str = ""  # Raw body text (for backwards compatibility)
    statements: List[FunctionStatement] = field(default_factory=list)  # Parsed statements
    is_native: bool = False  # Whether this is a native function
    library_path: str = ""  # Library path for native functions
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


# =============================================================================
# Expression to String Conversion
# =============================================================================

def expr_to_string(expr) -> str:
    """Convert an Expr AST node to string representation."""
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
        return f"{expr_to_string(expr.left)} {op_str} {expr_to_string(expr.right)}"
    elif isinstance(expr, UnaryExpr):
        op_map = {UnaryOperator.NOT: 'not ', UnaryOperator.NEG: '-'}
        op_str = op_map.get(expr.op, str(expr.op))
        return f"{op_str}{expr_to_string(expr.operand)}"
    elif isinstance(expr, FunctionCallExpr):
        args = ', '.join(expr_to_string(arg) for arg in expr.args)
        return f"{expr.name}({args})"
    elif isinstance(expr, FieldAccessExpr):
        return f"{expr_to_string(expr.object)}.{expr.field}"
    elif isinstance(expr, EnumRefExpr):
        return f"{expr.enum_name}.{expr.value}"
    elif isinstance(expr, LambdaExpr):
        return f"{expr.param} => {expr_to_string(expr.body)}"
    elif isinstance(expr, IfExpr):
        return f"IF {expr_to_string(expr.condition)} THEN {expr_to_string(expr.then_expr)} ELSE {expr_to_string(expr.else_expr)}"
    elif isinstance(expr, StructLiteralExpr):
        fields = ', '.join(f"{k}: {expr_to_string(v)}" for k, v in expr.fields.items())
        return f"{{{fields}}}"
    elif isinstance(expr, ListLiteralExpr):
        elements = ', '.join(expr_to_string(e) for e in expr.elements)
        return f"[{elements}]"
    elif isinstance(expr, IndexAccessExpr):
        return f"{expr_to_string(expr.object)}[{expr_to_string(expr.index)}]"
    elif isinstance(expr, DynamicFieldAccessExpr):
        return f"{expr_to_string(expr.object)}.{{{expr_to_string(expr.key_expr)}}}"
    else:
        return str(expr)
