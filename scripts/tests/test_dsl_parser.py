"""
Tests for the transaction DSL parser (PEG-based).
"""

import pytest
import sys
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from dsl_ast import (
    Schema, Transaction, Parameter, EnumDecl, MessageDecl, BlockDecl,
    ActorDecl, StateDecl, Transition, StoreAction, ComputeAction,
    SendAction, BroadcastAction, AppendAction, FunctionDecl,
    SimpleType, ListType, MapType,
    MessageTrigger, TimeoutTrigger, NamedTrigger,
    Identifier, StructLiteralExpr, BinaryExpr, BinaryOperator, UnaryExpr, UnaryOperator,
    FunctionCallExpr, Literal
)
from dsl_peg_parser import parse
from dsl_ast import expr_to_string


def type_to_str(type_expr) -> str:
    """Convert TypeExpr AST to string for test assertions."""
    if isinstance(type_expr, str):
        return type_expr
    elif isinstance(type_expr, SimpleType):
        return type_expr.name
    elif isinstance(type_expr, ListType):
        return f"list<{type_to_str(type_expr.element_type)}>"
    elif isinstance(type_expr, MapType):
        return f"map<{type_to_str(type_expr.key_type)}, {type_to_str(type_expr.value_type)}>"
    else:
        return str(type_expr)


def trigger_to_str(trigger) -> str:
    """Convert TriggerExpr AST to string for test assertions."""
    if trigger is None:
        return None
    elif isinstance(trigger, str):
        return trigger
    elif isinstance(trigger, MessageTrigger):
        return trigger.message_type
    elif isinstance(trigger, TimeoutTrigger):
        return f"timeout({trigger.parameter})"
    elif isinstance(trigger, NamedTrigger):
        return trigger.name
    else:
        return str(trigger)


def guard_to_str(guard) -> str:
    """Convert Expr AST (guard) to string for test assertions."""
    if guard is None:
        return None
    elif isinstance(guard, str):
        return guard
    else:
        return expr_to_string(guard)


def expr_to_str(expr) -> str:
    """Convert Expr AST to string for test assertions."""
    if expr is None:
        return None
    elif isinstance(expr, str):
        return expr
    else:
        return expr_to_string(expr)


def assignments_to_str(assignments: dict) -> dict:
    """Convert assignment dict with Expr values to string values for test assertions."""
    return {k: expr_to_str(v) for k, v in assignments.items()}


# =============================================================================
# Lexer Tests
# =============================================================================

# =============================================================================
# Parser Tests
# =============================================================================

class TestParserBasic:
    """Basic parser tests."""

    def test_empty_input(self):
        schema = parse("")
        assert schema.transaction is None
        assert schema.actors == []

    def test_transaction_declaration(self):
        schema = parse('transaction 01 "Cabal Attestation"')
        assert schema.transaction is not None
        assert schema.transaction.id == "01"
        assert schema.transaction.name == "Cabal Attestation"

    def test_imports(self):
        schema = parse("imports shared/common")
        assert len(schema.imports) == 1
        assert schema.imports[0].path == "shared/common"

    def test_comments_ignored(self):
        schema = parse("""
        # This is a comment
        transaction 01 "Test"
        # Another comment
        """)
        assert schema.transaction is not None


class TestParameters:
    """Tests for parameter parsing."""

    def test_simple_parameter(self):
        schema = parse("""
        parameters (
            TIMEOUT = 300 seconds "Description here"
        )
        """)
        assert len(schema.parameters) == 1
        param = schema.parameters[0]
        assert param.name == "TIMEOUT"
        assert param.value == 300
        assert param.unit == "seconds"
        assert param.description == "Description here"

    def test_float_parameter(self):
        schema = parse("""
        parameters (
            THRESHOLD = 0.67 fraction "Two thirds"
        )
        """)
        param = schema.parameters[0]
        assert param.value == 0.67
        assert param.unit == "fraction"

    def test_multiple_parameters(self):
        schema = parse("""
        parameters (
            A = 1 seconds
            B = 2 count
            C = 0.5 fraction
        )
        """)
        assert len(schema.parameters) == 3


class TestEnums:
    """Tests for enum parsing."""

    def test_simple_enum(self):
        schema = parse("""
        enum Status (
            PENDING
            ACTIVE
            DONE
        )
        """)
        assert len(schema.enums) == 1
        enum = schema.enums[0]
        assert enum.name == "Status"
        assert len(enum.values) == 3
        assert enum.values[0].name == "PENDING"

    def test_enum_with_comments(self):
        schema = parse("""
        enum Reason (
            NORMAL      # Normal completion
            ERROR       # Something went wrong
        )
        """)
        enum = schema.enums[0]
        assert enum.values[0].comment == "Normal completion"
        assert enum.values[1].comment == "Something went wrong"


class TestMessages:
    """Tests for message parsing."""

    def test_simple_message(self):
        schema = parse("""
        message VM_READY from Provider to [Consumer] (
            session_id   hash
            vm_info      dict
        )
        """)
        assert len(schema.messages) == 1
        msg = schema.messages[0]
        assert msg.name == "VM_READY"
        assert msg.sender == "Provider"
        assert msg.recipients == ["Consumer"]
        assert not msg.signed
        assert len(msg.fields) == 2

    def test_signed_message(self):
        schema = parse("""
        message VM_ALLOCATED from Provider to [Witness] signed (
            session_id   hash
        )
        """)
        msg = schema.messages[0]
        assert msg.signed

    def test_multiple_recipients(self):
        schema = parse("""
        message RESULT from Witness to [Consumer, Provider] (
            data   dict
        )
        """)
        msg = schema.messages[0]
        assert msg.recipients == ["Consumer", "Provider"]

    def test_generic_type_field(self):
        schema = parse("""
        message TEST from A to [B] (
            witnesses   list<peer_id>
            votes       map<string, bool>
        )
        """)
        msg = schema.messages[0]
        assert type_to_str(msg.fields[0].type) == "list<peer_id>"
        assert type_to_str(msg.fields[1].type) == "map<string, bool>"


class TestBlocks:
    """Tests for block parsing."""

    def test_simple_block(self):
        schema = parse("""
        block ATTESTATION by [Witness] (
            session_id   hash
            verified     bool
        )
        """)
        assert len(schema.blocks) == 1
        block = schema.blocks[0]
        assert block.name == "ATTESTATION"
        assert block.appended_by == ["Witness"]
        assert len(block.fields) == 2


class TestActors:
    """Tests for actor parsing."""

    def test_minimal_actor(self):
        schema = parse("""
        actor Consumer "Uses the service" (
            state IDLE initial
        )
        """)
        assert len(schema.actors) == 1
        actor = schema.actors[0]
        assert actor.name == "Consumer"
        assert actor.description == "Uses the service"
        assert len(actor.states) == 1
        assert actor.states[0].initial

    def test_actor_store(self):
        schema = parse("""
        actor Provider (
            store (
                session_id    hash
                consumer      peer_id
                witnesses     list<peer_id>
            )
            state IDLE initial
        )
        """)
        actor = schema.actors[0]
        assert len(actor.store) == 3
        assert actor.store[0].name == "session_id"
        assert type_to_str(actor.store[0].type) == "hash"
        assert type_to_str(actor.store[2].type) == "list<peer_id>"

    def test_actor_trigger(self):
        schema = parse("""
        actor Provider (
            trigger start_session(session_id hash, consumer peer_id, witnesses list<peer_id>)
                in [WAITING]
            state WAITING initial
        )
        """)
        actor = schema.actors[0]
        assert len(actor.triggers) == 1
        trigger = actor.triggers[0]
        assert trigger.name == "start_session"
        assert len(trigger.params) == 3
        assert trigger.params[0].name == "session_id"
        assert type_to_str(trigger.params[0].type) == "hash"
        assert trigger.params[1].name == "consumer"
        assert type_to_str(trigger.params[1].type) == "peer_id"
        assert trigger.params[2].name == "witnesses"
        assert type_to_str(trigger.params[2].type) == "list<peer_id>"
        assert trigger.allowed_in == ["WAITING"]

    def test_actor_states(self):
        schema = parse("""
        actor Provider (
            state WAITING initial "Waiting for request"
            state RUNNING "Processing"
            state DONE terminal
        )
        """)
        actor = schema.actors[0]
        assert len(actor.states) == 3
        assert actor.states[0].initial
        assert actor.states[0].description == "Waiting for request"
        assert actor.states[2].terminal


class TestTransitions:
    """Tests for transition parsing."""

    def test_simple_transition(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 on trigger_name
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.from_state == "S1"
        assert trans.to_state == "S2"
        assert trigger_to_str(trans.trigger) == "trigger_name"
        assert not trans.auto

    def test_auto_transition(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.auto
        assert trans.trigger is None

    def test_transition_with_guard(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when count > 0 and ready == true
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard_str = guard_to_str(trans.guard)
        assert "count > 0" in guard_str
        assert "ready == true" in guard_str

    def test_timeout_trigger(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 on timeout(DEADLINE)
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trigger_to_str(trans.trigger) == "timeout(DEADLINE)"

    def test_transition_with_store_action(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 on evt (
                store field1, field2, field3
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert len(trans.actions) == 1
        action = trans.actions[0]
        assert isinstance(action, StoreAction)
        assert action.fields == ["field1", "field2", "field3"]

    def test_transition_with_store_assignment(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 on evt (
                STORE(x, NOW())
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, StoreAction)
        assert assignments_to_str(action.assignments) == {"x": "NOW()"}

    def test_transition_with_assignment(self):
        """Assignment action in transition."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                result = HASH(data)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, ComputeAction)
        assert action.name == "result"
        assert expr_to_str(action.expression) == "HASH(data)"

    def test_transition_with_multiple_assignments(self):
        """Multiple bare assignments should work."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                result = HASH(data)
                other = x + y
            )
        )
        """)
        actions = schema.actors[0].transitions[0].actions
        assert len(actions) == 2
        assert isinstance(actions[0], ComputeAction)
        assert actions[0].name == "result"
        assert expr_to_str(actions[0].expression) == "HASH(data)"
        assert isinstance(actions[1], ComputeAction)
        assert actions[1].name == "other"

    def test_transition_with_send(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                SEND(consumer, MSG_TYPE)
                BROADCAST(witnesses, MSG_BROADCAST)
            )
        )
        """)
        actions = schema.actors[0].transitions[0].actions
        assert len(actions) == 2
        assert isinstance(actions[0], SendAction)
        assert actions[0].message == "MSG_TYPE"
        assert expr_to_str(actions[0].target) == "consumer"
        assert isinstance(actions[1], BroadcastAction)
        assert actions[1].message == "MSG_BROADCAST"
        assert expr_to_str(actions[1].target_list) == "witnesses"

    def test_transition_with_append(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 on MSG (
                APPEND(votes, message.payload)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, AppendAction)
        assert action.list_name == "votes"
        assert expr_to_str(action.value) == "message.payload"

    def test_transition_with_struct_compute(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                data = {
                    session_id session_id,
                    provider peer_id,
                    timestamp current_time
                }
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, ComputeAction)
        assert isinstance(action.expression, StructLiteralExpr)


class TestFunctions:
    """Tests for function parsing."""

    def test_simple_function(self):
        schema = parse("""
        function positive_ratio(votes list<dict>) -> float (
            count = LENGTH(FILTER(votes, v => v.can_reach_vm))
            return count / LENGTH(votes)
        )
        """)
        assert len(schema.functions) == 1
        func = schema.functions[0]
        assert func.name == "positive_ratio"
        assert len(func.params) == 1
        assert func.params[0].name == "votes"
        assert type_to_str(func.params[0].type) == "list<dict>"
        assert type_to_str(func.return_type) == "float"
        # func.body is empty now that we have statements, check statements instead
        assert len(func.statements) >= 1

    def test_function_no_params(self):
        schema = parse("""
        function check_connectivity() -> bool (
            return true
        )
        """)
        func = schema.functions[0]
        assert func.params == []
        assert type_to_str(func.return_type) == "bool"


# =============================================================================
# Integration Tests
# =============================================================================

class TestIntegration:
    """Integration tests with larger examples."""

    def test_minimal_complete_schema(self):
        source = """
        transaction 01 "Test"

        parameters (
            TIMEOUT = 60 seconds
        )

        enum Status (
            PENDING
            DONE
        )

        message REQUEST from Consumer to [Provider] (
            session_id hash
        )

        message RESPONSE from Provider to [Consumer] (
            result dict
        )

        actor Consumer (
            store (
                session_id hash
                result     dict
            )

            trigger start_session(session_id hash) in [IDLE]

            state IDLE initial
            state WAITING
            state DONE terminal

            IDLE -> WAITING on start_session (
                store session_id
                SEND(provider, REQUEST)
            )

            WAITING -> DONE on RESPONSE (
                STORE(result, message.payload.result)
            )
        )

        actor Provider (
            store (
                session_id hash
            )

            state IDLE initial

            IDLE -> IDLE on REQUEST (
                STORE(session_id, message.payload.session_id)
                SEND(consumer, RESPONSE)
            )
        )

        function check_valid() -> bool (
            return true
        )
        """

        schema = parse(source)
        assert schema.transaction.id == "01"
        assert len(schema.parameters) == 1
        assert len(schema.enums) == 1
        assert len(schema.messages) == 2
        assert len(schema.actors) == 2
        assert len(schema.functions) == 1


# =============================================================================
# Expression Parsing Tests (Parentheses)
# =============================================================================

from dsl_ast import (
    BinaryExpr, BinaryOperator, Identifier, Literal, FunctionCallExpr
)


class TestParenthesesHandling:
    """Tests for parentheses affecting AST structure (operator precedence)."""

    def test_parens_override_precedence(self):
        """(a + b) * c should group addition first, then multiply.

        Without parens: a + b * c would be a + (b * c) due to precedence
        With parens: (a + b) * c groups the addition first
        """
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (a + b) * c > 10
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        # Top level should be GT comparison
        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.GT

        # Left side of comparison should be MUL
        mul_expr = guard.left
        assert isinstance(mul_expr, BinaryExpr)
        assert mul_expr.op == BinaryOperator.MUL

        # Left of MUL should be ADD (this is the effect of parentheses)
        add_expr = mul_expr.left
        assert isinstance(add_expr, BinaryExpr)
        assert add_expr.op == BinaryOperator.ADD

        # Verify operands
        assert isinstance(add_expr.left, Identifier)
        assert add_expr.left.name == "a"
        assert isinstance(add_expr.right, Identifier)
        assert add_expr.right.name == "b"

    def test_operator_precedence_without_parens(self):
        """a + b * c should group multiplication first (higher precedence).

        Result: a + (b * c) - the MUL is nested inside ADD's right operand
        """
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when a + b * c > 10
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        # Top level should be GT comparison
        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.GT

        # Left side of comparison should be ADD
        add_expr = guard.left
        assert isinstance(add_expr, BinaryExpr)
        assert add_expr.op == BinaryOperator.ADD

        # Right of ADD should be MUL (due to precedence)
        mul_expr = add_expr.right
        assert isinstance(mul_expr, BinaryExpr)
        assert mul_expr.op == BinaryOperator.MUL

    def test_double_parentheses(self):
        """((count + offset)) should still produce correct AST (parens stripped)."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when ((count + offset)) > 0
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        # Top level should be GT
        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.GT

        # Left should be ADD (double parens don't affect structure)
        add_expr = guard.left
        assert isinstance(add_expr, BinaryExpr)
        assert add_expr.op == BinaryOperator.ADD

    def test_multiple_grouped_expressions(self):
        """(a + b) * (c + d) should group both additions."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (a + b) * (c + d) > limit
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        # Top: GT
        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.GT

        # Left of GT: MUL
        mul_expr = guard.left
        assert isinstance(mul_expr, BinaryExpr)
        assert mul_expr.op == BinaryOperator.MUL

        # Left of MUL: ADD (a + b)
        left_add = mul_expr.left
        assert isinstance(left_add, BinaryExpr)
        assert left_add.op == BinaryOperator.ADD

        # Right of MUL: ADD (c + d)
        right_add = mul_expr.right
        assert isinstance(right_add, BinaryExpr)
        assert right_add.op == BinaryOperator.ADD

    def test_parentheses_in_function_call(self):
        """HASH((a + b)) should have ADD as argument."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                result = HASH((a + b))
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, ComputeAction)

        # Expression should be HASH call
        expr = action.expression
        assert isinstance(expr, FunctionCallExpr)
        assert expr.name == "HASH"

        # Argument should be ADD
        assert len(expr.args) == 1
        arg = expr.args[0]
        assert isinstance(arg, BinaryExpr)
        assert arg.op == BinaryOperator.ADD

    def test_nested_parentheses_in_compute(self):
        """((a + b) * (c - d)) / e should have correct nesting."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                x = ((a + b) * (c - d)) / e
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        expr = action.expression

        # Top level: DIV
        assert isinstance(expr, BinaryExpr)
        assert expr.op == BinaryOperator.DIV

        # Left of DIV: MUL
        mul_expr = expr.left
        assert isinstance(mul_expr, BinaryExpr)
        assert mul_expr.op == BinaryOperator.MUL

        # Left of MUL: ADD (a + b)
        add_expr = mul_expr.left
        assert isinstance(add_expr, BinaryExpr)
        assert add_expr.op == BinaryOperator.ADD

        # Right of MUL: SUB (c - d)
        sub_expr = mul_expr.right
        assert isinstance(sub_expr, BinaryExpr)
        assert sub_expr.op == BinaryOperator.SUB

    def test_parentheses_with_comparison(self):
        """(count / total) >= THRESHOLD should group division first."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (count / total) >= THRESHOLD
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        # Top: GTE
        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.GTE

        # Left of GTE: DIV
        div_expr = guard.left
        assert isinstance(div_expr, BinaryExpr)
        assert div_expr.op == BinaryOperator.DIV

    def test_parentheses_with_logical_operators(self):
        """(a > 0 and b > 0) or (c > 0) should group AND first."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (a > 0 and b > 0) or (c > 0)
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        # Top: OR
        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.OR

        # Left of OR: AND
        and_expr = guard.left
        assert isinstance(and_expr, BinaryExpr)
        assert and_expr.op == BinaryOperator.AND

        # Right of OR: GT (c > 0)
        right_gt = guard.right
        assert isinstance(right_gt, BinaryExpr)
        assert right_gt.op == BinaryOperator.GT

    def test_parentheses_in_lambda(self):
        """Lambda bodies with parentheses should parse correctly."""
        schema = parse("""
        function count_valid(items list<dict>) -> uint (
            return LENGTH(FILTER(items, i => (i.score > 0) and (i.active == true)))
        )
        """)
        func = schema.functions[0]

        # Should have parsed statements (not just string body)
        assert len(func.statements) == 1

        # Get the return statement's expression
        ret_stmt = func.statements[0]
        length_call = ret_stmt.expression
        assert isinstance(length_call, FunctionCallExpr)
        assert length_call.name == "LENGTH"

    def test_unary_with_parentheses(self):
        """-(a + b) should negate the entire addition."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                x = -(a + b)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        from dsl_ast import UnaryExpr, UnaryOperator

        expr = action.expression
        assert isinstance(expr, UnaryExpr)
        assert expr.op == UnaryOperator.NEG

        # Operand should be ADD
        add_expr = expr.operand
        assert isinstance(add_expr, BinaryExpr)
        assert add_expr.op == BinaryOperator.ADD

    def test_unnecessary_parens_around_identifier(self):
        """(x) should parse the same as x."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (ready) == true
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.EQ
        # Left side should still be an identifier (parens stripped)
        assert isinstance(guard.left, Identifier)
        assert guard.left.name == "ready"

    def test_unnecessary_parens_around_literal(self):
        """(42) should parse the same as 42."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                x = (42) + 1
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        expr = action.expression

        assert isinstance(expr, BinaryExpr)
        assert expr.op == BinaryOperator.ADD
        assert isinstance(expr.left, Literal)
        assert expr.left.value == 42

    def test_unnecessary_parens_around_function_call(self):
        """(LENGTH(list)) should parse the same as LENGTH(list)."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (LENGTH(items)) > 0
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.GT
        assert isinstance(guard.left, FunctionCallExpr)
        assert guard.left.name == "LENGTH"

    def test_deeply_nested_unnecessary_parens(self):
        """(((x))) should parse the same as x."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (((count))) > 0
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.GT
        assert isinstance(guard.left, Identifier)
        assert guard.left.name == "count"

    def test_parens_mixed_single_and_multiline_guard(self):
        """Guard expression with parens spanning multiple lines."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (
                count > 0
            ) and (
                ready == true
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.AND

        # Left: count > 0
        assert isinstance(guard.left, BinaryExpr)
        assert guard.left.op == BinaryOperator.GT

        # Right: ready == true
        assert isinstance(guard.right, BinaryExpr)
        assert guard.right.op == BinaryOperator.EQ

    def test_parens_multiline_compute_expression(self):
        """Compute with expression spanning multiple lines using parens."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                result = (
                    base_value + offset
                ) * multiplier
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        expr = action.expression

        # Top: MUL
        assert isinstance(expr, BinaryExpr)
        assert expr.op == BinaryOperator.MUL

        # Left of MUL: ADD (from the parenthesized expression)
        assert isinstance(expr.left, BinaryExpr)
        assert expr.left.op == BinaryOperator.ADD

    def test_parens_multiline_function_args(self):
        """Function call with parenthesized args on multiple lines."""
        schema = parse("""
        function check(items list<dict>) -> bool (
            return LENGTH(FILTER(
                items,
                i => (i.active == true) and (i.score > 0)
            )) > 0
        )
        """)
        func = schema.functions[0]
        assert len(func.statements) == 1

        ret_stmt = func.statements[0]
        # Should be a comparison: LENGTH(...) > 0
        assert isinstance(ret_stmt.expression, BinaryExpr)
        assert ret_stmt.expression.op == BinaryOperator.GT

    def test_parens_complex_multiline_guard(self):
        """Complex guard with multiple parenthesized groups across lines."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto when (
                (a > 0 and b > 0)
                or
                (c > 0 and d > 0)
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard = trans.guard

        # Top: OR
        assert isinstance(guard, BinaryExpr)
        assert guard.op == BinaryOperator.OR

        # Both sides should be AND
        assert isinstance(guard.left, BinaryExpr)
        assert guard.left.op == BinaryOperator.AND
        assert isinstance(guard.right, BinaryExpr)
        assert guard.right.op == BinaryOperator.AND

    def test_parens_in_struct_literal_values(self):
        """Parentheses around values in struct literals."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                data = {
                    total (base + extra),
                    ratio (count / max)
                }
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]

        expr = action.expression
        assert isinstance(expr, StructLiteralExpr)

        # total field should be ADD
        assert "total" in expr.fields
        total_expr = expr.fields["total"]
        assert isinstance(total_expr, BinaryExpr)
        assert total_expr.op == BinaryOperator.ADD

        # ratio field should be DIV
        assert "ratio" in expr.fields
        ratio_expr = expr.fields["ratio"]
        assert isinstance(ratio_expr, BinaryExpr)
        assert ratio_expr.op == BinaryOperator.DIV


# =============================================================================
# Whitespace Tolerance Tests
# =============================================================================

class TestWhitespaceTolerance:
    """Tests that the parser handles varying whitespace correctly."""

    def test_message_with_extra_whitespace(self):
        """Parser should handle extra whitespace in message declarations."""
        schema = parse("""
        message   LOCK_INTENT
            from   Consumer
            to   [ Provider , Witness ]
            signed
        (
            session_id   hash
            amount       uint
        )
        """)
        assert len(schema.messages) == 1
        msg = schema.messages[0]
        assert msg.name == "LOCK_INTENT"
        assert msg.sender == "Consumer"
        assert msg.recipients == ["Provider", "Witness"]
        assert msg.signed is True

    def test_block_with_extra_whitespace(self):
        """Parser should handle extra whitespace in block declarations."""
        schema = parse("""
        block   BALANCE_LOCK
            by   [ Consumer , Provider ]
        (
            session_id   hash
        )
        """)
        assert len(schema.blocks) == 1
        block = schema.blocks[0]
        assert block.name == "BALANCE_LOCK"
        assert block.appended_by == ["Consumer", "Provider"]

    def test_send_action_with_whitespace(self):
        """Parser should handle extra whitespace in SEND actions."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                SEND(   provider   ,   LOCK_INTENT   )
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, SendAction)
        assert isinstance(action.target, Identifier)
        assert action.target.name == "provider"
        assert action.message == "LOCK_INTENT"

    def test_send_action_multiline(self):
        """Parser should handle multiline SEND actions."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                SEND(
                    provider,
                    LOCK_INTENT
                )
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, SendAction)
        assert isinstance(action.target, Identifier)
        assert action.target.name == "provider"
        assert action.message == "LOCK_INTENT"

    def test_broadcast_action_with_whitespace(self):
        """Parser should handle extra whitespace in BROADCAST actions."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                BROADCAST(   witnesses   ,   NOTIFY   )
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, BroadcastAction)
        assert action.target_list == "witnesses"
        assert action.message == "NOTIFY"

    def test_append_action_with_whitespace(self):
        """Parser should handle extra whitespace in APPEND actions."""
        schema = parse("""
        actor A (
            store (
                results   list<hash>
            )
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                APPEND(   results   ,   my_hash   )
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, AppendAction)
        assert action.list_name == "results"

    def test_store_function_style_with_whitespace(self):
        """Parser should handle extra whitespace in function-style STORE."""
        schema = parse("""
        actor A (
            store (
                my_value   uint
            )
            state S1 initial
            state S2 terminal
            S1 -> S2 on LOCK_MSG (
                STORE(   my_value   ,   message.amount   )
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, StoreAction)
        assert "my_value" in action.assignments

    def test_transition_with_extra_whitespace(self):
        """Parser should handle extra whitespace around transition syntax."""
        schema = parse("""
        actor A (
            trigger start_action( x uint , y hash ) in [ S1 ]
            state S1 initial
            state S2 terminal
            S1   ->   S2   on   start_action   when   x > 0   (
                result = x + 1
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.from_state == "S1"
        assert trans.to_state == "S2"

    def test_type_with_extra_whitespace(self):
        """Parser should handle extra whitespace in type declarations."""
        schema = parse("""
        message M from A to [B] (
            field1   list<   uint   >
            field2   map<   string   ,   hash   >
        )
        """)
        assert len(schema.messages) == 1
        msg = schema.messages[0]
        assert type_to_str(msg.fields[0].type) == "list<uint>"
        assert type_to_str(msg.fields[1].type) == "map<string, hash>"

    def test_function_params_with_whitespace(self):
        """Parser should handle extra whitespace in function parameters."""
        schema = parse("""
        function foo(   a   uint   ,   b   string   ) -> bool (
            return true
        )
        """)
        func = schema.functions[0]
        assert func.name == "foo"
        assert len(func.params) == 2
        assert func.params[0].name == "a"
        assert func.params[1].name == "b"


# =============================================================================
# Difficult Parsing Cases
# =============================================================================

class TestDifficultParsingCases:
    """Tests for ambiguous or tricky parsing scenarios.

    These test cases document edge cases in the grammar where the parser
    must make context-sensitive decisions. The key challenge is distinguishing:
    - Guard expressions from function calls: `when foo(x)` vs `when foo (store x)`
    - Action blocks from function arguments: `(store x)` vs `(x + 1)`

    The parser uses keyword lookahead to distinguish these cases:
    - If token after `(` is an action keyword (store, send, etc.) -> action block
    - If token after `(` is an expression token -> function call argument
    """

    def test_guard_with_function_call(self):
        """Guard containing a function call: foo(x) is the guard."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on MSG when validate(data) (
                store result
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        # Guard should be the function call validate(data)
        guard_str = expr_to_str(trans.guard)
        assert guard_str == "validate(data)"

    def test_guard_with_simple_identifier(self):
        """Guard is a simple identifier followed by action block."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on MSG when is_valid (
                store result
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        # Guard should be just the identifier
        guard_str = expr_to_str(trans.guard)
        assert guard_str == "is_valid"

    def test_guard_with_comparison(self):
        """Guard with comparison operator."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on MSG when count >= threshold (
                store result
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard_str = expr_to_str(trans.guard)
        assert guard_str == "count >= threshold"

    def test_guard_with_nested_function_calls(self):
        """Guard with nested function calls."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto when LENGTH(FILTER(items, x => x.valid)) >= MIN_COUNT (
                store result
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        # The entire expression should be parsed as the guard
        assert trans.guard is not None

    def test_action_block_starts_with_keyword(self):
        """Action block is recognized by starting keyword."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                store x
                SEND(target, MSG)
                result = HASH(data)
            )
        )
        """)
        actions = schema.actors[0].transitions[0].actions
        assert len(actions) == 3
        assert isinstance(actions[0], StoreAction)
        assert isinstance(actions[1], SendAction)
        assert isinstance(actions[2], ComputeAction)

    def test_function_call_with_expression_args(self):
        """Function call arguments are expressions, not actions."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto when validate(x + 1, y * 2) (
                store result
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        guard_str = expr_to_str(trans.guard)
        assert "validate" in guard_str
        assert "x + 1" in guard_str

    def test_guard_function_vs_action_block_distinction(self):
        """The critical distinction: action keywords after ( mean action block."""
        # This is a function call in the guard
        schema1 = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on MSG when check(value) (
                store x
            )
        )
        """)
        guard1 = expr_to_str(schema1.actors[0].transitions[0].guard)
        assert guard1 == "check(value)"

        # This has a simple guard followed by action block
        schema2 = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on MSG when is_ready (
                store x
            )
        )
        """)
        guard2 = expr_to_str(schema2.actors[0].transitions[0].guard)
        assert guard2 == "is_ready"

    def test_empty_action_block(self):
        """Empty action block is valid."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto ()
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.actions == []

    def test_guard_with_struct_literal(self):
        """Guard can contain struct literals."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto when result == {status "OK"} (
                store x
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.guard is not None

    def test_guard_with_list_literal(self):
        """Guard can contain list literals."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto when CONTAINS([1, 2, 3], value) (
                store x
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.guard is not None

    def test_multiline_guard_expression(self):
        """Guard expression can span multiple lines inside parens."""
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto when (
                is_valid
                and has_permission
                and count >= threshold
            ) (
                store result
            )
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.guard is not None
        # All three conditions should be ANDed together
        guard_str = expr_to_str(trans.guard)
        assert "and" in guard_str.lower() or "AND" in guard_str


# =============================================================================
# Error Handling Tests
# =============================================================================

# Import Lark exceptions for error handling tests
from lark.exceptions import UnexpectedCharacters, UnexpectedToken, UnexpectedEOF

class TestErrorHandling:
    """Tests for error handling."""

    def test_missing_paren(self):
        with pytest.raises((UnexpectedCharacters, UnexpectedToken, UnexpectedEOF)):
            parse("""
            parameters (
                X = 1
            # Missing closing paren
            """)

    def test_unexpected_token(self):
        with pytest.raises((UnexpectedCharacters, UnexpectedToken)):
            parse("invalid_top_level_keyword foo")

    def test_missing_arrow_in_transition(self):
        with pytest.raises((UnexpectedCharacters, UnexpectedToken)):
            parse("""
            actor A (
                state S1 initial
                state S2
                S1 S2 on trigger
            )
            """)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
