"""
PEG-based parser for the transaction DSL using Lark.

Uses a formal grammar definition (dsl_grammar.lark) and Lark's Earley parser
to produce AST nodes defined in dsl_ast.py.
"""

from pathlib import Path
from lark import Lark, Transformer, v_args
from typing import List, Optional, Dict, Any

from dsl_ast import (
    Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
    MessageDecl, BlockDecl, Field, ActorDecl, StateDecl, TriggerDecl,
    TriggerParam, Transition, StoreAction, ComputeAction, LookupAction,
    SendAction, BroadcastAction, AppendAction,
    OnGuardFail, FunctionDecl, FunctionParam, ReturnStmt, AssignmentStmt,
    ForStmt,
    # Expression AST
    Identifier, Literal, BinaryExpr, UnaryExpr, FunctionCallExpr,
    FieldAccessExpr, DynamicFieldAccessExpr, IndexAccessExpr,
    LambdaExpr, StructLiteralExpr, ListLiteralExpr, EnumRefExpr, IfExpr,
    BinaryOperator, UnaryOperator,
    # Type AST
    SimpleType, ListType, MapType,
    # Trigger AST
    MessageTrigger, TimeoutTrigger, NamedTrigger,
)


# Load grammar from file
GRAMMAR_PATH = Path(__file__).parent / "dsl_grammar.lark"


@v_args(inline=True)
class DSLTransformer(Transformer):
    """Transform Lark parse tree into our AST nodes."""

    # =========================================================================
    # Top-level
    # =========================================================================

    def start(self, *items):
        from lark import Token
        schema = Schema()
        for item in items:
            if item is None:
                continue
            # Skip comments at top level
            if isinstance(item, Token) and item.type == 'COMMENT':
                continue
            decl = item
            if isinstance(decl, Transaction):
                schema.transaction = decl
            elif isinstance(decl, Import):
                schema.imports.append(decl)
            elif isinstance(decl, list) and all(isinstance(p, Parameter) for p in decl):
                schema.parameters.extend(decl)
            elif isinstance(decl, EnumDecl):
                schema.enums.append(decl)
            elif isinstance(decl, MessageDecl):
                schema.messages.append(decl)
            elif isinstance(decl, BlockDecl):
                schema.blocks.append(decl)
            elif isinstance(decl, ActorDecl):
                schema.actors.append(decl)
            elif isinstance(decl, FunctionDecl):
                schema.functions.append(decl)
        return schema

    def declaration(self, decl):
        return decl

    # =========================================================================
    # Transaction
    # =========================================================================

    def transaction_decl(self, tx_id, name, description=None):
        return Transaction(
            id=str(tx_id),
            name=self._unquote(name),
            description=self._unquote(description) if description else None
        )

    # =========================================================================
    # Imports
    # =========================================================================

    def imports_decl(self, path):
        return Import(path=path)

    def import_path(self, *parts):
        return "/".join(str(p) for p in parts)

    # =========================================================================
    # Parameters
    # =========================================================================

    def parameters_block(self, *params):
        return [p for p in params if isinstance(p, Parameter)]

    def parameter(self, name, value, unit=None, description=None):
        val = str(value)
        if '.' in val:
            val = float(val)
        else:
            try:
                val = int(val)
            except ValueError:
                pass  # Keep as string
        return Parameter(
            name=str(name),
            value=val,
            unit=str(unit) if unit and not str(unit).startswith('"') else None,
            description=self._unquote(description) if description else None
        )

    # =========================================================================
    # Enums
    # =========================================================================

    def enum_decl(self, name, *rest):
        description = None
        values = []
        for item in rest:
            if isinstance(item, str) and item.startswith('"'):
                description = self._unquote(item)
            elif isinstance(item, EnumValue):
                values.append(item)
        return EnumDecl(name=str(name), description=description, values=values)

    def enum_value(self, name, comment=None):
        return EnumValue(
            name=str(name),
            comment=str(comment)[1:].strip() if comment else None
        )

    # =========================================================================
    # Messages
    # =========================================================================

    def message_decl(self, name, sender, recipients, *rest):
        signed = False
        fields = []
        for item in rest:
            if str(item) == "signed":
                signed = True
            elif isinstance(item, Field):
                fields.append(item)
        return MessageDecl(
            name=str(name),
            sender=str(sender),
            recipients=recipients,
            signed=signed,
            fields=fields
        )

    # =========================================================================
    # Blocks
    # =========================================================================

    def block_decl(self, name, appended_by, *fields):
        return BlockDecl(
            name=str(name),
            appended_by=appended_by,
            fields=[f for f in fields if isinstance(f, Field)]
        )

    # =========================================================================
    # Fields and types
    # =========================================================================

    def field(self, name, type_expr):
        return Field(name=str(name), type=type_expr)

    def simple_type(self, name):
        return SimpleType(name=str(name))

    def generic_type(self, name, *type_args):
        name_str = str(name)
        if name_str.lower() == "list":
            return ListType(element_type=type_args[0])
        elif name_str.lower() == "map":
            return MapType(key_type=type_args[0], value_type=type_args[1])
        else:
            # Generic type we don't specially handle
            return SimpleType(name=f"{name_str}<{', '.join(str(t) for t in type_args)}>")

    def identifier_list(self, *ids):
        return [str(i) for i in ids]

    # =========================================================================
    # Actors
    # =========================================================================

    def actor_decl(self, name, *rest):
        description = None
        store = []
        triggers = []
        states = []
        transitions = []

        for item in rest:
            if isinstance(item, str) and item.startswith('"'):
                description = self._unquote(item)
            elif isinstance(item, list) and item and isinstance(item[0], Field):
                store = item
            elif isinstance(item, TriggerDecl):
                triggers.append(item)
            elif isinstance(item, StateDecl):
                states.append(item)
            elif isinstance(item, Transition):
                transitions.append(item)

        return ActorDecl(
            name=str(name),
            description=description,
            store=store,
            triggers=triggers,
            states=states,
            transitions=transitions
        )

    def actor_body(self, item):
        return item

    def store_block(self, *fields):
        return [f for f in fields if isinstance(f, Field)]

    def trigger_decl(self, name, *rest):
        params = []
        allowed_in = []
        description = None

        for item in rest:
            if isinstance(item, list):
                if item and isinstance(item[0], TriggerParam):
                    params = item
                else:
                    allowed_in = item
            elif isinstance(item, str) and item.startswith('"'):
                description = self._unquote(item)

        return TriggerDecl(
            name=str(name),
            params=params,
            allowed_in=allowed_in,
            description=description
        )

    def trigger_params(self, *params):
        return list(params)

    def trigger_param(self, name, type_expr):
        return TriggerParam(name=str(name), type=type_expr)

    def state_decl(self, name, *rest):
        initial = False
        terminal = False
        description = None

        for item in rest:
            item_str = str(item) if item else ""
            if item_str == "initial":
                initial = True
            elif item_str == "terminal":
                terminal = True
            elif item_str.startswith('"'):
                description = self._unquote(item)

        return StateDecl(
            name=str(name),
            initial=initial,
            terminal=terminal,
            description=description
        )

    def state_modifier(self, mod):
        return str(mod)

    # =========================================================================
    # Transitions
    # =========================================================================

    def _build_transition(self, from_state, to_state, trigger, *rest):
        """Build a Transition from parsed components."""
        guard = None
        actions = []
        on_guard_fail = None

        for item in rest:
            if isinstance(item, (Identifier, BinaryExpr, UnaryExpr, FunctionCallExpr,
                                 FieldAccessExpr, Literal, IfExpr)):
                guard = item
            elif isinstance(item, list):
                actions = item
            elif isinstance(item, OnGuardFail):
                on_guard_fail = item

        auto = isinstance(trigger, tuple) and trigger[0] == "auto"

        return Transition(
            from_state=str(from_state),
            to_state=str(to_state),
            trigger=None if auto else trigger,
            auto=auto,
            guard=guard,
            actions=actions,
            on_guard_fail=on_guard_fail
        )

    def guarded_transition(self, from_state, to_state, trigger, guard, *rest):
        """Transition with guard clause (may have else)."""
        return self._build_transition(from_state, to_state, trigger, guard, *rest)

    def simple_transition(self, from_state, to_state, trigger, *rest):
        """Transition without guard (no else allowed)."""
        return self._build_transition(from_state, to_state, trigger, *rest)

    def auto_trigger(self):
        return ("auto", None)

    def named_trigger(self, name):
        name_str = str(name)
        if name_str.isupper():
            return MessageTrigger(message_type=name_str)
        return NamedTrigger(name=name_str)

    def timeout_trigger(self, param):
        return TimeoutTrigger(parameter=str(param))

    def guard_clause(self, expr):
        return expr

    def action_block(self, *actions):
        return [a for a in actions if a is not None and not isinstance(a, str)]

    def else_clause(self, target, actions=None):
        return OnGuardFail(
            target=str(target),
            actions=actions if actions else []
        )

    # =========================================================================
    # Actions
    # =========================================================================

    def action(self, a):
        return a

    def store_fields(self, *fields):
        return StoreAction(fields=[str(f) for f in fields])

    def store_assign(self, key, value):
        action = StoreAction()
        action.assignments[str(key)] = value
        return action

    def lookup_action(self, name, expr):
        return LookupAction(name=str(name), expression=expr)

    def send_action(self, target, message):
        # Keep target as AST node for generator compatibility
        return SendAction(message=str(message), target=target)

    def broadcast_action(self, target_list, message):
        return BroadcastAction(message=str(message), target_list=str(target_list))

    def append_action(self, list_name, value):
        return AppendAction(list_name=str(list_name), value=value)

    def assignment_action(self, name, expr):
        return ComputeAction(name=str(name), expression=expr)

    # =========================================================================
    # Functions
    # =========================================================================

    def function_decl(self, name, *rest):
        params = []
        return_type = SimpleType(name="void")
        statements = []
        stmt_types = (ReturnStmt, AssignmentStmt, ForStmt)

        for item in rest:
            if isinstance(item, list) and item and isinstance(item[0], FunctionParam):
                params = item
            elif isinstance(item, (SimpleType, ListType, MapType)):
                return_type = item
            elif isinstance(item, stmt_types):
                statements.append(item)
            elif isinstance(item, list):
                # Block statement - flatten it
                statements.extend(s for s in item if isinstance(s, stmt_types))

        return FunctionDecl(
            name=str(name),
            params=params,
            return_type=return_type,
            statements=statements
        )

    def native_function_decl(self, name, *rest):
        params = []
        return_type = SimpleType(name="void")
        library_path = ""

        for item in rest:
            if isinstance(item, list) and item and isinstance(item[0], FunctionParam):
                params = item
            elif isinstance(item, (SimpleType, ListType, MapType)):
                return_type = item
            elif isinstance(item, str) and item.startswith('"'):
                library_path = self._unquote(item)

        return FunctionDecl(
            name=str(name),
            params=params,
            return_type=return_type,
            is_native=True,
            library_path=library_path
        )

    def function_params(self, *params):
        return list(params)

    def function_param(self, name, type_expr):
        return FunctionParam(name=str(name), type=type_expr)

    def function_body(self, stmt):
        return stmt

    def return_stmt(self, expr):
        return ReturnStmt(expression=expr)

    def assignment_stmt(self, name, expr):
        return AssignmentStmt(name=str(name), expression=expr)

    def index_assignment(self, name, index, expr):
        return AssignmentStmt(name=str(name), expression=expr, index=index)

    def for_stmt(self, var, iterable, body_stmt):
        # body_stmt could be a single statement or a list (from block_stmt)
        if isinstance(body_stmt, list):
            body = body_stmt
        elif isinstance(body_stmt, (ReturnStmt, AssignmentStmt, ForStmt)):
            body = [body_stmt]
        else:
            body = []
        return ForStmt(var_name=str(var), iterable=iterable, body=body)

    def block_stmt(self, *items):
        return self._flatten_stmts(items)

    def _flatten_stmts(self, items):
        """Flatten statement list, expanding any block_stmt lists."""
        stmt_types = (ReturnStmt, AssignmentStmt, ForStmt)
        result = []
        for item in items:
            if isinstance(item, list):
                # Nested block_stmt - flatten it
                result.extend(s for s in item if isinstance(s, stmt_types))
            elif isinstance(item, stmt_types):
                result.append(item)
        return result

    # =========================================================================
    # Expressions
    # =========================================================================

    def binary_or(self, left, right):
        return BinaryExpr(left=left, op=BinaryOperator.OR, right=right)

    def binary_and(self, left, right):
        return BinaryExpr(left=left, op=BinaryOperator.AND, right=right)

    def unary_not(self, operand):
        return UnaryExpr(op=UnaryOperator.NOT, operand=operand)

    def binary_comp(self, left, op, right):
        op_map = {
            "==": BinaryOperator.EQ,
            "!=": BinaryOperator.NEQ,
            "<": BinaryOperator.LT,
            ">": BinaryOperator.GT,
            "<=": BinaryOperator.LTE,
            ">=": BinaryOperator.GTE,
        }
        return BinaryExpr(left=left, op=op_map[str(op)], right=right)

    def binary_add(self, left, right):
        return BinaryExpr(left=left, op=BinaryOperator.ADD, right=right)

    def binary_sub(self, left, right):
        return BinaryExpr(left=left, op=BinaryOperator.SUB, right=right)

    def binary_mul(self, left, right):
        return BinaryExpr(left=left, op=BinaryOperator.MUL, right=right)

    def binary_div(self, left, right):
        return BinaryExpr(left=left, op=BinaryOperator.DIV, right=right)

    def unary_neg(self, operand):
        return UnaryExpr(op=UnaryOperator.NEG, operand=operand)

    def func_call(self, func, args=None):
        if isinstance(func, Identifier):
            return FunctionCallExpr(name=func.name, args=args or [])
        # If it's already a more complex expression, wrap it
        # This handles chained calls like foo()(x)
        return FunctionCallExpr(name="<expr>", args=args or [])

    def field_access(self, obj, field):
        return FieldAccessExpr(object=obj, field=str(field))

    def dynamic_field(self, obj, key_expr):
        return DynamicFieldAccessExpr(object=obj, key_expr=key_expr)

    def index_access(self, obj, index):
        return IndexAccessExpr(object=obj, index=index)

    def grouped(self, expr):
        return expr

    def list_literal(self, args=None):
        return ListLiteralExpr(elements=args or [])

    def struct_literal(self, fields=None):
        if fields is None:
            return StructLiteralExpr()
        struct = StructLiteralExpr()
        for name, value, is_spread in fields:
            if is_spread:
                struct.spread = value
            else:
                struct.fields[name] = value
        return struct

    def struct_fields(self, *fields):
        return list(fields)

    def named_field(self, name, value):
        return (str(name), value, False)

    def shorthand_field(self, name):
        # Shorthand: { foo } means { foo: foo }
        name_str = str(name)
        return (name_str, Identifier(name=name_str), False)

    def spread_field(self, value):
        return (None, value, True)

    def if_expr(self, cond, then_expr, else_expr):
        return IfExpr(condition=cond, then_expr=then_expr, else_expr=else_expr)

    def lambda_expr(self, param, body):
        return LambdaExpr(param=str(param), body=body)

    def enum_ref(self, enum_name, value):
        return EnumRefExpr(enum_name=str(enum_name), value=str(value))

    def args(self, *exprs):
        return list(exprs)

    def identifier(self, name):
        return Identifier(name=str(name))

    def number(self, n):
        val = str(n)
        if '.' in val:
            return Literal(value=float(val), type="number")
        return Literal(value=int(val), type="number")

    def string(self, s):
        return Literal(value=self._unquote(s), type="string")

    def true_lit(self):
        return Literal(value=True, type="bool")

    def false_lit(self):
        return Literal(value=False, type="bool")

    def null_lit(self):
        return Literal(value=None, type="null")

    # =========================================================================
    # Helpers
    # =========================================================================

    def _unquote(self, s):
        """Remove quotes from a string token."""
        if s is None:
            return None
        s = str(s)
        if s.startswith('"') and s.endswith('"'):
            return s[1:-1]
        return s


# Create parser instance
_parser = None


def get_parser():
    """Get or create the Lark parser instance."""
    global _parser
    if _parser is None:
        with open(GRAMMAR_PATH) as f:
            grammar = f.read()
        _parser = Lark(
            grammar,
            parser='earley',  # Earley parser handles ambiguity better
            propagate_positions=True,
            maybe_placeholders=True,
        )
    return _parser


def parse(source: str) -> Schema:
    """Parse DSL source code into an AST Schema."""
    parser = get_parser()
    tree = parser.parse(source)
    transformer = DSLTransformer()
    return transformer.transform(tree)


def parse_file(path: str) -> Schema:
    """Parse a DSL file into an AST Schema."""
    with open(path) as f:
        return parse(f.read())


# =============================================================================
# Import Resolution
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


if __name__ == "__main__":
    # Simple test
    test_source = '''
    transaction 00 "Test Transaction"

    parameters (
        TIMEOUT = 300 seconds
    )

    enum Status (
        PENDING
        COMPLETE
    )

    message MSG from A to [B] (
        value uint
    )

    actor A (
        state IDLE initial
        state DONE terminal

        IDLE -> DONE auto (
            result = HASH(data)
        )
    )
    '''

    schema = parse(test_source)
    print(f"Transaction: {schema.transaction.name if schema.transaction else 'None'}")
    print(f"Parameters: {len(schema.parameters)}")
    print(f"Enums: {len(schema.enums)}")
    print(f"Messages: {len(schema.messages)}")
    print(f"Actors: {len(schema.actors)}")
