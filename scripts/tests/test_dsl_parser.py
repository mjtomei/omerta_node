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
    SendAction, BroadcastAction, AppendAction, FunctionDecl
)
from dsl_parser import Parser, parse, ParseError
from dsl_converter import ast_to_dict, convert_dsl_source


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
        assert msg.fields[0].type == "list<peer_id>"
        assert msg.fields[1].type == "map<string, bool>"


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
        assert actor.store[0].type == "hash"
        assert actor.store[2].type == "list<peer_id>"

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
        assert trigger.params[0].type == "hash"
        assert trigger.params[1].name == "consumer"
        assert trigger.params[1].type == "peer_id"
        assert trigger.params[2].name == "witnesses"
        assert trigger.params[2].type == "list<peer_id>"
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
        assert trans.trigger == "trigger_name"
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
        assert "count > 0" in trans.guard
        assert "ready == true" in trans.guard

    def test_timeout_trigger(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2
            S1 -> S2 on timeout(DEADLINE)
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.trigger == "timeout(DEADLINE)"

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
        assert action.assignments == {"x": "NOW()"}

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
        assert action.expression == "HASH(data)"

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
        assert actions[0].target == "consumer"
        assert isinstance(actions[1], BroadcastAction)
        assert actions[1].message == "MSG_BROADCAST"
        assert actions[1].target_list == "witnesses"

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
        assert action.value == "message.payload"

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
        assert "session_id = session_id" in action.expression


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
        assert func.params[0].type == "list<dict>"
        assert func.return_type == "float"
        assert "LENGTH" in func.body

    def test_function_no_params(self):
        schema = parse("""
        function check_connectivity() -> bool (
            return true
        )
        """)
        func = schema.functions[0]
        assert func.params == []
        assert func.return_type == "bool"


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
