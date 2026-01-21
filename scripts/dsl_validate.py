"""
Semantic validation for transaction DSL ASTs.

These checks run after parsing but before code generation to catch
errors that the grammar can't express.
"""

from dataclasses import dataclass, field
from typing import List, Set, Dict, Optional, Tuple, Any
from dsl_ast import (
    Schema, ActorDecl, Transition, FunctionDecl, MessageDecl, BlockDecl,
    StoreAction, ComputeAction, LookupAction, SendAction, BroadcastAction,
    AppendAction, AppendBlockAction, TriggerDecl,
    Identifier, FunctionCallExpr, FieldAccessExpr, EnumRefExpr,
    BinaryExpr, UnaryExpr, IfExpr, IndexAccessExpr, StructLiteralExpr,
    ListLiteralExpr, Literal, LambdaExpr, DynamicFieldAccessExpr,
    Expr, FunctionStatement, AssignmentStmt, ReturnStmt, ForStmt, IfStmt,
    BinaryOperator, Field,
)


def _type_to_str(type_val) -> str:
    """Convert a type value (string or AST node) to string."""
    if isinstance(type_val, str):
        return type_val
    if hasattr(type_val, 'name'):
        return type_val.name
    return str(type_val)


@dataclass
class ValidationError:
    """A validation error with location info."""
    message: str
    line: int = 0
    column: int = 0
    severity: str = "error"  # "error" or "warning"

    def __str__(self):
        loc = f"line {self.line}" if self.line else "unknown location"
        return f"[{self.severity}] {loc}: {self.message}"


@dataclass
class ValidationResult:
    """Result of validation."""
    errors: List[ValidationError] = field(default_factory=list)
    warnings: List[ValidationError] = field(default_factory=list)

    @property
    def has_errors(self) -> bool:
        return len(self.errors) > 0

    @property
    def has_warnings(self) -> bool:
        return len(self.warnings) > 0

    def add_error(self, message: str, line: int = 0, column: int = 0):
        self.errors.append(ValidationError(message, line, column, "error"))

    def add_warning(self, message: str, line: int = 0, column: int = 0):
        self.warnings.append(ValidationError(message, line, column, "warning"))

    def merge(self, other: 'ValidationResult'):
        self.errors.extend(other.errors)
        self.warnings.extend(other.warnings)

    def __str__(self):
        lines = []
        for err in self.errors:
            lines.append(str(err))
        for warn in self.warnings:
            lines.append(str(warn))
        return "\n".join(lines)


# =============================================================================
# Built-in functions that don't need to be declared
# =============================================================================

BUILTIN_FUNCTIONS = {
    # Core operations
    "LOAD", "HASH", "SIGN", "VERIFY", "NOW", "READ",
    # Collections
    "LENGTH", "MAP", "FILTER", "FIND", "REDUCE", "CONCAT", "APPEND", "SORT",
    "KEYS",
    # Logic
    "IF", "NOT", "AND", "OR",
    # Math
    "ABS", "SUM",
    # Crypto
    "SEEDED_RNG", "SEEDED_SAMPLE", "RANDOM_BYTES",
    # Chain
    "CHAIN_CONTAINS", "CHAIN_STATE_AT", "VERIFY_CHAIN_SEGMENT",
    "CHAIN_CONTAINS_HASH", "CHAIN_SEGMENT",
    # Other
    "HAS_KEY", "ABORT",
}

# Impure functions that shouldn't be in pure function bodies
IMPURE_FUNCTIONS = {"STORE", "SEND", "BROADCAST"}

# Primitive types
PRIMITIVE_TYPES = {
    "string", "str", "int", "uint", "float", "bool", "boolean",
    "hash", "signature", "bytes", "timestamp", "peer_id", "any", "void",
}

# Numeric types for arithmetic validation
NUMERIC_TYPES = {"int", "uint", "float", "timestamp", "number", "count"}


# =============================================================================
# Schema Context for Validation
# =============================================================================

@dataclass
class SchemaContext:
    """Context for validation containing all schema-level definitions."""
    enum_names: Set[str] = field(default_factory=set)
    enum_values: Dict[str, str] = field(default_factory=dict)  # value -> enum_name
    message_names: Set[str] = field(default_factory=set)
    message_fields: Dict[str, Dict[str, str]] = field(default_factory=dict)  # msg -> {field -> type}
    block_names: Set[str] = field(default_factory=set)
    block_fields: Dict[str, Dict[str, str]] = field(default_factory=dict)  # block -> {field -> type}
    function_names: Set[str] = field(default_factory=set)
    function_signatures: Dict[str, Tuple[List[str], str]] = field(default_factory=dict)  # name -> (param_types, return_type)
    parameter_names: Set[str] = field(default_factory=set)
    struct_names: Set[str] = field(default_factory=set)  # Custom struct types (enums, messages used as types)

    @classmethod
    def from_schema(cls, schema: Schema) -> 'SchemaContext':
        ctx = cls()

        # Enums
        for enum in schema.enums:
            ctx.enum_names.add(enum.name)
            ctx.struct_names.add(enum.name)
            for v in enum.values:
                ctx.enum_values[v.name] = enum.name

        # Messages
        for msg in schema.messages:
            ctx.message_names.add(msg.name)
            ctx.struct_names.add(msg.name)
            ctx.message_fields[msg.name] = {f.name: _type_to_str(f.type) for f in msg.fields}

        # Blocks
        for block in schema.blocks:
            ctx.block_names.add(block.name)
            ctx.struct_names.add(block.name)
            ctx.block_fields[block.name] = {f.name: _type_to_str(f.type) for f in block.fields}

        # Functions
        for func in schema.functions:
            ctx.function_names.add(func.name)
            param_types = [_type_to_str(p.type) for p in func.params]
            return_type = _type_to_str(func.return_type)
            ctx.function_signatures[func.name] = (param_types, return_type)

        # Parameters
        ctx.parameter_names = {p.name for p in schema.parameters}

        return ctx

    def merge(self, other: 'SchemaContext'):
        """Merge another context into this one (for imports)."""
        self.enum_names.update(other.enum_names)
        self.enum_values.update(other.enum_values)
        self.message_names.update(other.message_names)
        self.message_fields.update(other.message_fields)
        self.block_names.update(other.block_names)
        self.block_fields.update(other.block_fields)
        self.function_names.update(other.function_names)
        self.function_signatures.update(other.function_signatures)
        self.parameter_names.update(other.parameter_names)
        self.struct_names.update(other.struct_names)


# =============================================================================
# Main Validation Entry Points
# =============================================================================

def validate_schema(schema: Schema, imported_schemas: List[Schema] = None) -> ValidationResult:
    """Run all validations on a schema.

    Args:
        schema: The schema to validate
        imported_schemas: List of imported schemas whose definitions should be available
    """
    result = ValidationResult()
    ctx = SchemaContext.from_schema(schema)

    # Merge imported definitions into context
    if imported_schemas:
        for imported in imported_schemas:
            imported_ctx = SchemaContext.from_schema(imported)
            ctx.merge(imported_ctx)

    # Validate each actor
    for actor in schema.actors:
        result.merge(validate_actor(actor, ctx))

    # Validate functions
    for func in schema.functions:
        result.merge(validate_function(func, ctx))

    # Validate no object types
    result.merge(validate_no_object_types(schema))

    return result


def validate_and_report(schema: Schema, raise_on_error: bool = True) -> ValidationResult:
    """
    Validate a schema and optionally raise on errors.

    Args:
        schema: The schema to validate
        raise_on_error: If True, raise ValueError on validation errors

    Returns:
        ValidationResult with all errors and warnings
    """
    result = validate_schema(schema)

    if result.has_errors and raise_on_error:
        raise ValueError(f"Schema validation failed:\n{result}")

    return result


# =============================================================================
# Actor Validation
# =============================================================================

def validate_actor(actor: ActorDecl, ctx: SchemaContext) -> ValidationResult:
    """Validate an actor declaration."""
    result = ValidationResult()

    # Collect actor-level information
    state_names = {s.name for s in actor.states}
    initial_states = [s for s in actor.states if s.initial]
    terminal_states = [s for s in actor.states if s.terminal]
    store_vars = {f.name: _type_to_str(f.type) for f in actor.store}
    trigger_names = {t.name for t in actor.triggers}

    # Check for initial state
    if not initial_states:
        result.add_error(
            f"Actor '{actor.name}' has no initial state",
            actor.line
        )
    elif len(initial_states) > 1:
        names = [s.name for s in initial_states]
        result.add_error(
            f"Actor '{actor.name}' has multiple initial states: {names}",
            actor.line
        )

    # Warn if no terminal states
    if not terminal_states:
        result.add_warning(
            f"Actor '{actor.name}' has no terminal states",
            actor.line
        )

    # Check for duplicate states
    seen_states = set()
    for state in actor.states:
        if state.name in seen_states:
            result.add_error(
                f"Duplicate state '{state.name}' in actor '{actor.name}'",
                state.line
            )
        seen_states.add(state.name)

    # Validate transitions
    for trans in actor.transitions:
        result.merge(validate_transition(
            trans, actor.name, state_names, trigger_names, store_vars, ctx
        ))

    # Validate triggers
    for trigger in actor.triggers:
        result.merge(validate_trigger(trigger, actor.name, state_names))

    # Check for unreachable states
    result.merge(check_unreachable_states(actor, state_names, initial_states))

    return result


def validate_transition(
    trans: Transition,
    actor_name: str,
    state_names: Set[str],
    trigger_names: Set[str],
    store_vars: Dict[str, str],
    ctx: SchemaContext,
) -> ValidationResult:
    """Validate a transition."""
    result = ValidationResult()

    # Check from_state exists
    if trans.from_state not in state_names:
        result.add_error(
            f"Transition references unknown state '{trans.from_state}' in actor '{actor_name}'",
            trans.line
        )

    # Check to_state exists
    if trans.to_state not in state_names:
        result.add_error(
            f"Transition references unknown target state '{trans.to_state}' in actor '{actor_name}'",
            trans.line
        )

    # Check trigger/message
    if trans.trigger and not trans.auto:
        trigger_name = _get_trigger_name(trans.trigger)
        if trigger_name:
            is_message = trigger_name in ctx.message_names
            is_trigger = trigger_name in trigger_names
            is_timeout = trigger_name.startswith("timeout(")

            if not is_message and not is_trigger and not is_timeout:
                result.add_error(
                    f"Transition trigger '{trigger_name}' is neither a message nor a declared trigger in actor '{actor_name}'",
                    trans.line
                )

    # Validate guard expression
    if trans.guard:
        result.merge(validate_expression(
            trans.guard, f"guard in {actor_name}", store_vars, ctx
        ))

    # Validate actions
    for action in trans.actions:
        result.merge(validate_action(action, actor_name, store_vars, ctx))

    # Validate on_guard_fail
    if trans.on_guard_fail:
        if trans.on_guard_fail.target not in state_names:
            result.add_error(
                f"on_guard_fail target '{trans.on_guard_fail.target}' not found in actor '{actor_name}'",
                trans.on_guard_fail.line
            )
        for action in trans.on_guard_fail.actions:
            result.merge(validate_action(action, actor_name, store_vars, ctx))

    return result


def validate_action(
    action,
    actor_name: str,
    store_vars: Dict[str, str],
    ctx: SchemaContext,
) -> ValidationResult:
    """Validate a transition action."""
    result = ValidationResult()
    location = f"action in {actor_name}"

    if isinstance(action, SendAction):
        if action.message not in ctx.message_names:
            result.add_error(
                f"SEND references unknown message '{action.message}' in {actor_name}",
                action.line
            )
        # Validate target expression
        if action.target and not isinstance(action.target, str):
            result.merge(validate_expression(action.target, location, store_vars, ctx))

    elif isinstance(action, BroadcastAction):
        if action.message not in ctx.message_names:
            result.add_error(
                f"BROADCAST references unknown message '{action.message}' in {actor_name}",
                action.line
            )
        # Validate target list expression
        if action.target_list and not isinstance(action.target_list, str):
            result.merge(validate_expression(action.target_list, location, store_vars, ctx))

    elif isinstance(action, AppendBlockAction):
        block_type = action.block_type
        if hasattr(block_type, 'name'):
            block_type = block_type.name
        if block_type not in ctx.block_names:
            result.add_error(
                f"APPEND references unknown block type '{block_type}' in {actor_name}",
                action.line
            )

    elif isinstance(action, StoreAction):
        # Validate store expressions
        if action.assignments:
            for key, val in action.assignments.items():
                if not isinstance(val, str):
                    result.merge(validate_expression(val, location, store_vars, ctx))

    elif isinstance(action, (ComputeAction, LookupAction)):
        # Validate the expression
        expr = action.expression
        if expr and not isinstance(expr, str):
            result.merge(validate_expression(expr, location, store_vars, ctx))

    return result


def validate_trigger(
    trigger: TriggerDecl,
    actor_name: str,
    state_names: Set[str],
) -> ValidationResult:
    """Validate a trigger declaration."""
    result = ValidationResult()

    for state in trigger.allowed_in:
        if state not in state_names:
            result.add_error(
                f"Trigger '{trigger.name}' references unknown state '{state}' in allowed_in",
                trigger.line
            )

    return result


def check_unreachable_states(
    actor: ActorDecl,
    state_names: Set[str],
    initial_states: list,
) -> ValidationResult:
    """Check for states that can't be reached from initial state."""
    result = ValidationResult()

    if not initial_states:
        return result

    reachable = set()
    to_visit = [s.name for s in initial_states]

    while to_visit:
        state = to_visit.pop()
        if state in reachable:
            continue
        reachable.add(state)

        for trans in actor.transitions:
            if trans.from_state == state and trans.to_state not in reachable:
                to_visit.append(trans.to_state)
            if trans.on_guard_fail and trans.from_state == state:
                if trans.on_guard_fail.target not in reachable:
                    to_visit.append(trans.on_guard_fail.target)

    unreachable = state_names - reachable
    for state_name in unreachable:
        result.add_warning(
            f"State '{state_name}' in actor '{actor.name}' is unreachable from initial state",
            actor.line
        )

    return result


# =============================================================================
# Function Validation
# =============================================================================

def validate_function(func: FunctionDecl, ctx: SchemaContext) -> ValidationResult:
    """Validate a function declaration."""
    result = ValidationResult()

    if func.is_native:
        return result

    # Build local scope (parameters)
    local_vars = {p.name: _type_to_str(p.type) for p in func.params}

    # Check purity and validate expressions
    for stmt in func.statements:
        result.merge(validate_function_statement(stmt, func.name, local_vars, ctx))

    return result


def validate_function_statement(
    stmt: FunctionStatement,
    func_name: str,
    local_vars: Dict[str, str],
    ctx: SchemaContext,
) -> ValidationResult:
    """Validate a function statement."""
    result = ValidationResult()
    location = f"function {func_name}"

    if isinstance(stmt, ForStmt):
        # Validate iterable
        if stmt.iterable and not isinstance(stmt.iterable, str):
            result.merge(validate_expression(stmt.iterable, location, local_vars, ctx))
        # Add loop variable to scope for body
        inner_vars = dict(local_vars)
        inner_vars[stmt.var_name] = "any"  # Could infer from iterable type
        for inner in stmt.body:
            result.merge(validate_function_statement(inner, func_name, inner_vars, ctx))

    elif isinstance(stmt, IfStmt):
        # Validate condition
        if stmt.condition and not isinstance(stmt.condition, str):
            result.merge(validate_expression(stmt.condition, location, local_vars, ctx))
        for inner in stmt.then_body:
            result.merge(validate_function_statement(inner, func_name, local_vars, ctx))
        for inner in stmt.else_body:
            result.merge(validate_function_statement(inner, func_name, local_vars, ctx))

    elif isinstance(stmt, AssignmentStmt):
        # Check for impure operations
        result.merge(_check_expr_purity(stmt.expression, func_name, stmt.line))
        # Validate expression
        if stmt.expression and not isinstance(stmt.expression, str):
            result.merge(validate_expression(stmt.expression, location, local_vars, ctx))
        # Add variable to scope
        local_vars[stmt.name] = "any"

    elif isinstance(stmt, ReturnStmt):
        # Check for impure operations
        result.merge(_check_expr_purity(stmt.expression, func_name, stmt.line))
        # Validate expression
        if stmt.expression and not isinstance(stmt.expression, str):
            result.merge(validate_expression(stmt.expression, location, local_vars, ctx))

    return result


def _check_expr_purity(expr, func_name: str, line: int) -> ValidationResult:
    """Check an expression for impure function calls."""
    result = ValidationResult()

    if isinstance(expr, str):
        for impure in IMPURE_FUNCTIONS:
            if f"{impure}(" in expr:
                result.add_error(
                    f"Function '{func_name}' contains impure operation '{impure}' - functions must be pure",
                    line
                )
        return result

    if isinstance(expr, FunctionCallExpr):
        if expr.name.upper() in IMPURE_FUNCTIONS:
            result.add_error(
                f"Function '{func_name}' calls impure operation '{expr.name}' - functions must be pure",
                expr.line
            )
        for arg in expr.args:
            result.merge(_check_expr_purity(arg, func_name, expr.line))

    elif hasattr(expr, '__dataclass_fields__'):
        for field_name in expr.__dataclass_fields__:
            if field_name in ('line', 'column'):
                continue
            field_val = getattr(expr, field_name, None)
            if field_val is not None:
                if isinstance(field_val, list):
                    for item in field_val:
                        if hasattr(item, '__dataclass_fields__') or isinstance(item, str):
                            result.merge(_check_expr_purity(item, func_name, line))
                elif hasattr(field_val, '__dataclass_fields__'):
                    result.merge(_check_expr_purity(field_val, func_name, line))

    return result


# =============================================================================
# Expression Validation
# =============================================================================

def validate_expression(
    expr,
    location: str,
    local_vars: Dict[str, str],
    ctx: SchemaContext,
) -> ValidationResult:
    """Validate an expression, checking references and types."""
    result = ValidationResult()

    if expr is None or isinstance(expr, str):
        return result

    line = getattr(expr, 'line', 0)

    if isinstance(expr, Identifier):
        # Note: We don't warn about undefined variables because DSL functions
        # can reference actor state variables loaded via LOAD() which we can't
        # statically verify without actor context.
        pass

    elif isinstance(expr, EnumRefExpr):
        # Validate enum reference
        if expr.enum_name not in ctx.enum_names:
            result.add_error(
                f"Reference to undefined enum '{expr.enum_name}' in {location}",
                line
            )
        elif expr.value not in ctx.enum_values:
            result.add_error(
                f"Enum '{expr.enum_name}' has no value '{expr.value}' in {location}",
                line
            )
        elif ctx.enum_values.get(expr.value) != expr.enum_name:
            result.add_error(
                f"Value '{expr.value}' belongs to enum '{ctx.enum_values.get(expr.value)}', not '{expr.enum_name}' in {location}",
                line
            )

    elif isinstance(expr, FunctionCallExpr):
        # Validate function exists
        func_name = expr.name
        func_upper = func_name.upper()
        if (func_upper not in BUILTIN_FUNCTIONS and
            func_name not in ctx.function_names and
            func_upper not in ctx.function_names):
            result.add_error(
                f"Call to undefined function '{func_name}' in {location}",
                line
            )

        # Validate LOAD references
        if func_upper == "LOAD" and expr.args:
            first_arg = expr.args[0]
            if isinstance(first_arg, Literal) and first_arg.type == "string":
                var_name = first_arg.value
                if var_name not in local_vars:
                    # LOAD references store variables - can't fully validate without actor context
                    pass

        # Validate arguments recursively
        for arg in expr.args:
            result.merge(validate_expression(arg, location, local_vars, ctx))

    elif isinstance(expr, FieldAccessExpr):
        # Validate base expression
        result.merge(validate_expression(expr.object, location, local_vars, ctx))

        # Check field exists on known types
        base_type = _infer_type(expr.object, local_vars, ctx)
        if base_type in ctx.message_fields:
            if expr.field not in ctx.message_fields[base_type]:
                result.add_warning(
                    f"Field '{expr.field}' may not exist on message '{base_type}' in {location}",
                    line
                )
        elif base_type in ctx.block_fields:
            if expr.field not in ctx.block_fields[base_type]:
                result.add_warning(
                    f"Field '{expr.field}' may not exist on block '{base_type}' in {location}",
                    line
                )

    elif isinstance(expr, BinaryExpr):
        result.merge(validate_expression(expr.left, location, local_vars, ctx))
        result.merge(validate_expression(expr.right, location, local_vars, ctx))

        # Type check arithmetic operations (only MUL/DIV, since ADD is used for concatenation)
        if expr.op in (BinaryOperator.MUL, BinaryOperator.DIV):
            left_type = _infer_type(expr.left, local_vars, ctx)
            right_type = _infer_type(expr.right, local_vars, ctx)
            if left_type and left_type not in NUMERIC_TYPES and left_type != "any":
                result.add_warning(
                    f"Arithmetic operation on non-numeric type '{left_type}' in {location}",
                    line
                )
            if right_type and right_type not in NUMERIC_TYPES and right_type != "any":
                result.add_warning(
                    f"Arithmetic operation on non-numeric type '{right_type}' in {location}",
                    line
                )

    elif isinstance(expr, UnaryExpr):
        result.merge(validate_expression(expr.operand, location, local_vars, ctx))

    elif isinstance(expr, IfExpr):
        result.merge(validate_expression(expr.condition, location, local_vars, ctx))
        result.merge(validate_expression(expr.then_expr, location, local_vars, ctx))
        result.merge(validate_expression(expr.else_expr, location, local_vars, ctx))

    elif isinstance(expr, IndexAccessExpr):
        result.merge(validate_expression(expr.object, location, local_vars, ctx))
        result.merge(validate_expression(expr.index, location, local_vars, ctx))

    elif isinstance(expr, DynamicFieldAccessExpr):
        result.merge(validate_expression(expr.object, location, local_vars, ctx))
        result.merge(validate_expression(expr.key_expr, location, local_vars, ctx))

    elif isinstance(expr, StructLiteralExpr):
        if expr.spread:
            result.merge(validate_expression(expr.spread, location, local_vars, ctx))
        for field_val in expr.fields.values():
            result.merge(validate_expression(field_val, location, local_vars, ctx))

    elif isinstance(expr, ListLiteralExpr):
        for elem in expr.elements:
            result.merge(validate_expression(elem, location, local_vars, ctx))

    elif isinstance(expr, LambdaExpr):
        # Add lambda parameter to scope
        inner_vars = dict(local_vars)
        inner_vars[expr.param] = "any"
        result.merge(validate_expression(expr.body, location, inner_vars, ctx))

    elif isinstance(expr, Literal):
        pass  # Literals are always valid

    return result


def _infer_type(expr, local_vars: Dict[str, str], ctx: SchemaContext) -> Optional[str]:
    """Attempt to infer the type of an expression. Returns None if unknown."""
    if expr is None:
        return None

    if isinstance(expr, Literal):
        return expr.type

    if isinstance(expr, Identifier):
        if expr.name in local_vars:
            return local_vars[expr.name]
        return None

    if isinstance(expr, EnumRefExpr):
        return expr.enum_name

    if isinstance(expr, FunctionCallExpr):
        func_name = expr.name
        if func_name in ctx.function_signatures:
            return ctx.function_signatures[func_name][1]
        # Built-in function return types
        if func_name.upper() == "LENGTH":
            return "int"
        if func_name.upper() == "NOW":
            return "timestamp"
        if func_name.upper() == "HASH":
            return "hash"
        if func_name.upper() == "SIGN":
            return "signature"
        return None

    if isinstance(expr, BinaryExpr):
        if expr.op in (BinaryOperator.EQ, BinaryOperator.NEQ, BinaryOperator.LT,
                       BinaryOperator.GT, BinaryOperator.LTE, BinaryOperator.GTE,
                       BinaryOperator.AND, BinaryOperator.OR):
            return "bool"
        # Arithmetic returns the type of operands
        left_type = _infer_type(expr.left, local_vars, ctx)
        right_type = _infer_type(expr.right, local_vars, ctx)
        if left_type in NUMERIC_TYPES:
            return left_type
        if right_type in NUMERIC_TYPES:
            return right_type
        return None

    if isinstance(expr, IfExpr):
        return _infer_type(expr.then_expr, local_vars, ctx)

    if isinstance(expr, StructLiteralExpr):
        return "dict"

    if isinstance(expr, ListLiteralExpr):
        return "list"

    return None


# =============================================================================
# Type Validation
# =============================================================================

def validate_no_object_types(schema: Schema) -> ValidationResult:
    """Validate that transaction doesn't use 'object' or 'list[object]' types."""
    result = ValidationResult()

    def is_disallowed(type_str: str) -> bool:
        if not isinstance(type_str, str):
            return False
        type_str = type_str.strip()
        if type_str == "object":
            return True
        if "object" in type_str and ("list<" in type_str or "list[" in type_str):
            return True
        return False

    for msg in schema.messages:
        for fld in msg.fields:
            if is_disallowed(fld.type):
                result.add_error(
                    f"Message '{msg.name}' field '{fld.name}': type '{fld.type}' not allowed, use explicit struct types",
                    fld.line
                )

    for actor in schema.actors:
        for fld in actor.store:
            if is_disallowed(fld.type):
                result.add_error(
                    f"Actor '{actor.name}' store field '{fld.name}': type '{fld.type}' not allowed, use explicit struct types",
                    fld.line
                )

    for block in schema.blocks:
        for fld in block.fields:
            if is_disallowed(fld.type):
                result.add_error(
                    f"Block '{block.name}' field '{fld.name}': type '{fld.type}' not allowed, use explicit struct types",
                    fld.line
                )

    return result


# =============================================================================
# Helpers
# =============================================================================

def _get_trigger_name(trigger) -> Optional[str]:
    """Extract trigger name from various trigger representations."""
    if isinstance(trigger, str):
        return trigger
    elif hasattr(trigger, 'name'):
        return trigger.name
    elif hasattr(trigger, 'message'):
        return trigger.message
    return None
