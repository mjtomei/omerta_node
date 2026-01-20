"""
Tests for the transaction DSL parser.
"""

import pytest
import sys
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from dsl_lexer import Lexer, Token, TokenType, tokenize, LexerError
from dsl_ast import (
    Schema, Transaction, Parameter, EnumDecl, MessageDecl, BlockDecl,
    ActorDecl, StateDecl, Transition, StoreAction, ComputeAction,
    SendAction, BroadcastAction, AppendAction, FunctionDecl,
    SimpleType, ListType, MapType,
    MessageTrigger, TimeoutTrigger, NamedTrigger
)
from dsl_parser import Parser, parse, ParseError
from dsl_converter import ast_to_dict, convert_dsl_source


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
        # Use the converter's _expr_to_string function
        from dsl_converter import _expr_to_string
        return _expr_to_string(guard)


def expr_to_str(expr) -> str:
    """Convert Expr AST to string for test assertions."""
    if expr is None:
        return None
    elif isinstance(expr, str):
        return expr
    else:
        from dsl_converter import _expr_to_string
        return _expr_to_string(expr)


def assignments_to_str(assignments: dict) -> dict:
    """Convert assignment dict with Expr values to string values for test assertions."""
    return {k: expr_to_str(v) for k, v in assignments.items()}


# =============================================================================
# Lexer Tests
# =============================================================================

class TestLexer:
    """Tests for the lexer."""

    def test_empty_input(self):
        tokens = tokenize("")
        assert len(tokens) == 1
        assert tokens[0].type == TokenType.EOF

    def test_keywords(self):
        tokens = tokenize("transaction enum message actor")
        types = [t.type for t in tokens if t.type != TokenType.EOF]
        assert types == [
            TokenType.TRANSACTION, TokenType.ENUM,
            TokenType.MESSAGE, TokenType.ACTOR
        ]

    def test_identifiers(self):
        tokens = tokenize("foo Bar BAZ_123 _private")
        ids = [t.value for t in tokens if t.type == TokenType.IDENTIFIER]
        assert ids == ["foo", "Bar", "BAZ_123", "_private"]

    def test_numbers(self):
        tokens = tokenize("42 3.14 0.5 100")
        nums = [t.value for t in tokens if t.type == TokenType.NUMBER]
        assert nums == ["42", "3.14", "0.5", "100"]

    def test_strings(self):
        tokens = tokenize('"hello" "world with spaces" "escape\\"quote"')
        strings = [t.value for t in tokens if t.type == TokenType.STRING]
        assert strings == ["hello", "world with spaces", 'escape"quote']

    def test_operators(self):
        tokens = tokenize("-> <- = == != <= >= + - * /")
        types = [t.type for t in tokens if t.type != TokenType.EOF]
        assert types == [
            TokenType.ARROW, TokenType.LARROW, TokenType.EQUALS,
            TokenType.EQ, TokenType.NEQ, TokenType.LTE, TokenType.GTE,
            TokenType.PLUS, TokenType.MINUS, TokenType.STAR, TokenType.SLASH
        ]

    def test_brackets(self):
        tokens = tokenize("( ) [ ] < >")
        types = [t.type for t in tokens if t.type != TokenType.EOF]
        assert types == [
            TokenType.LPAREN, TokenType.RPAREN,
            TokenType.LBRACKET, TokenType.RBRACKET,
            TokenType.LANGLE, TokenType.RANGLE
        ]

    def test_comments(self):
        tokens = tokenize("foo # this is a comment\nbar")
        assert any(t.type == TokenType.COMMENT for t in tokens)
        ids = [t.value for t in tokens if t.type == TokenType.IDENTIFIER]
        assert ids == ["foo", "bar"]

    def test_line_tracking(self):
        tokens = tokenize("line1\nline2\nline3")
        lines = [t.line for t in tokens if t.type == TokenType.IDENTIFIER]
        assert lines == [1, 2, 3]

    def test_unterminated_string(self):
        with pytest.raises(LexerError):
            tokenize('"unclosed string')

    def test_generic_type(self):
        tokens = tokenize("list<peer_id>")
        types = [t.type for t in tokens if t.type != TokenType.EOF]
        assert types == [
            TokenType.IDENTIFIER, TokenType.LANGLE,
            TokenType.IDENTIFIER, TokenType.RANGLE
        ]


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

    def test_transition_with_compute(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 auto (
                compute result = HASH(data)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, ComputeAction)
        assert action.name == "result"
        assert expr_to_str(action.expression) == "HASH(data)"

    def test_transition_with_bare_assignment(self):
        """Bare assignment (without compute keyword) should work."""
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
                compute data = (
                    session_id = session_id
                    provider = peer_id
                    timestamp = current_time
                )
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, ComputeAction)
        expr_str = expr_to_str(action.expression)
        assert "session_id = session_id" in expr_str


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
# Schema Conversion Tests
# =============================================================================

class TestSchemaConversion:
    """Tests for converting AST to schema dict."""

    def test_transaction_conversion(self):
        schema = parse('transaction 01 "Test Transaction"')
        result = ast_to_dict(schema)
        assert result['transaction']['id'] == '01'
        assert result['transaction']['name'] == 'Test Transaction'

    def test_parameter_conversion(self):
        schema = parse("""
        parameters (
            TIMEOUT = 300 seconds "Wait time"
        )
        """)
        result = ast_to_dict(schema)
        assert 'parameters' in result
        assert result['parameters']['TIMEOUT']['value'] == 300
        assert result['parameters']['TIMEOUT']['unit'] == 'seconds'

    def test_enum_conversion(self):
        schema = parse("""
        enum Status (
            PENDING
            DONE
        )
        """)
        result = ast_to_dict(schema)
        assert 'enums' in result
        assert result['enums']['Status']['values'] == ['PENDING', 'DONE']

    def test_message_conversion(self):
        schema = parse("""
        message TEST from A to [B, C] signed (
            id   hash
            data list<string>
        )
        """)
        result = ast_to_dict(schema)
        msg = result['messages']['TEST']
        assert msg['sender'] == 'A'
        assert msg['recipients'] == ['B', 'C']
        assert msg['signed_by'] == 'a'
        assert msg['fields']['data']['type'] == 'list[string]'  # Converted brackets

    def test_actor_conversion(self):
        schema = parse("""
        actor Provider "Provides service" (
            store (
                session_id hash
            )
            trigger start(id hash) in [IDLE]
            state IDLE initial
            state RUNNING
            IDLE -> RUNNING on start (
                store session_id
            )
        )
        """)
        result = ast_to_dict(schema)
        actor = result['actors']['Provider']
        assert actor['description'] == 'Provides service'
        assert actor['store_schema']['session_id'] == 'hash'
        assert actor['initial_state'] == 'IDLE'
        assert len(actor['transitions']) == 1

    def test_type_conversion(self):
        """Test that angle brackets are converted to square brackets."""
        schema = parse("""
        actor A (
            store (
                items list<string>
                mapping map<peer_id, bool>
            )
            state S initial
        )
        """)
        result = ast_to_dict(schema)
        store = result['actors']['A']['store_schema']
        assert store['items'] == 'list[string]'
        assert store['mapping'] == 'map[peer_id, bool]'


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

        # Convert to dict
        result = ast_to_dict(schema)
        assert 'transaction' in result
        assert 'parameters' in result
        assert 'enums' in result
        assert 'messages' in result
        assert 'actors' in result
        assert 'functions' in result


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
                compute result = HASH((a + b))
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
                compute x = ((a + b) * (c - d)) / e
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
                compute x = -(a + b)
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
                compute x = (42) + 1
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
                compute result = (
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
                compute data = (
                    total = (base + extra)
                    ratio = (count / max)
                )
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        from dsl_ast import StructLiteralExpr

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
        assert action.target == "provider"
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
        assert action.target == "provider"
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
                compute result = x + 1
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
# Error Handling Tests
# =============================================================================

class TestErrorHandling:
    """Tests for error handling."""

    def test_missing_paren(self):
        with pytest.raises(ParseError):
            parse("""
            parameters (
                X = 1
            # Missing closing paren
            """)

    def test_unexpected_token(self):
        with pytest.raises(ParseError):
            parse("invalid_top_level_keyword foo")

    def test_missing_arrow_in_transition(self):
        with pytest.raises(ParseError):
            parse("""
            actor A (
                state S1 initial
                state S2
                S1 S2 on trigger
            )
            """)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
