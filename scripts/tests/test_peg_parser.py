"""
Tests for the PEG-based DSL parser.

These tests verify that the Lark-based parser produces the same AST
as the hand-written recursive descent parser.
"""

import pytest
import sys
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from dsl_peg_parser import parse
from dsl_ast import (
    Schema, Transaction, Parameter, EnumDecl, MessageDecl, BlockDecl,
    ActorDecl, StateDecl, Transition, StoreAction, ComputeAction,
    SendAction, BroadcastAction, AppendAction, FunctionDecl,
    SimpleType, ListType, MapType,
    MessageTrigger, TimeoutTrigger, NamedTrigger,
    Identifier, Literal, BinaryExpr, FunctionCallExpr, BinaryOperator,
)


class TestPEGBasic:
    """Basic parsing tests."""

    def test_empty_input(self):
        schema = parse("")
        assert schema is not None
        assert schema.transaction is None

    def test_transaction_declaration(self):
        schema = parse('transaction 01 "Test Transaction"')
        assert schema.transaction is not None
        assert schema.transaction.id == "01"
        assert schema.transaction.name == "Test Transaction"

    def test_transaction_with_description(self):
        schema = parse('transaction 01 "Test" "A test transaction"')
        assert schema.transaction.name == "Test"
        assert schema.transaction.description == "A test transaction"

    def test_parameters(self):
        schema = parse("""
        parameters (
            TIMEOUT = 300 seconds "Wait time"
            THRESHOLD = 0.67 fraction
        )
        """)
        assert len(schema.parameters) == 2
        assert schema.parameters[0].name == "TIMEOUT"
        assert schema.parameters[0].value == 300
        assert schema.parameters[0].unit == "seconds"
        assert schema.parameters[1].name == "THRESHOLD"
        assert schema.parameters[1].value == 0.67


class TestPEGEnums:
    """Enum parsing tests."""

    def test_simple_enum(self):
        schema = parse("""
        enum Status (
            PENDING
            COMPLETE
            FAILED
        )
        """)
        assert len(schema.enums) == 1
        assert schema.enums[0].name == "Status"
        assert len(schema.enums[0].values) == 3

    def test_enum_with_description(self):
        schema = parse("""
        enum Status "Status codes" (
            OK
            ERROR
        )
        """)
        assert schema.enums[0].description == "Status codes"


class TestPEGMessages:
    """Message parsing tests."""

    def test_simple_message(self):
        schema = parse("""
        message MSG from Sender to [Receiver] (
            value uint
        )
        """)
        assert len(schema.messages) == 1
        msg = schema.messages[0]
        assert msg.name == "MSG"
        assert msg.sender == "Sender"
        assert msg.recipients == ["Receiver"]
        assert msg.signed is False

    def test_signed_message(self):
        schema = parse("""
        message MSG from A to [B, C] signed (
            data hash
        )
        """)
        msg = schema.messages[0]
        assert msg.signed is True
        assert msg.recipients == ["B", "C"]


class TestPEGBlocks:
    """Block parsing tests."""

    def test_simple_block(self):
        schema = parse("""
        block LOCK by [Consumer] (
            amount uint
            timestamp timestamp
        )
        """)
        assert len(schema.blocks) == 1
        block = schema.blocks[0]
        assert block.name == "LOCK"
        assert block.appended_by == ["Consumer"]
        assert len(block.fields) == 2


class TestPEGActors:
    """Actor parsing tests."""

    def test_minimal_actor(self):
        schema = parse("""
        actor Consumer (
            state IDLE initial
        )
        """)
        assert len(schema.actors) == 1
        actor = schema.actors[0]
        assert actor.name == "Consumer"
        assert len(actor.states) == 1

    def test_actor_with_store(self):
        schema = parse("""
        actor A (
            store (
                session_id hash
                amount uint
            )
            state S initial
        )
        """)
        actor = schema.actors[0]
        assert len(actor.store) == 2
        assert actor.store[0].name == "session_id"

    def test_actor_with_states(self):
        schema = parse("""
        actor A (
            state IDLE initial
            state WORKING
            state DONE terminal
        )
        """)
        actor = schema.actors[0]
        assert len(actor.states) == 3
        assert actor.states[0].initial is True
        assert actor.states[2].terminal is True


class TestPEGTransitions:
    """Transition parsing tests."""

    def test_auto_transition(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto ()
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.from_state == "S1"
        assert trans.to_state == "S2"
        assert trans.auto is True

    def test_message_trigger(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on MSG ()
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert isinstance(trans.trigger, MessageTrigger)
        assert trans.trigger.message_type == "MSG"

    def test_named_trigger(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on start_action ()
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert isinstance(trans.trigger, NamedTrigger)
        assert trans.trigger.name == "start_action"

    def test_timeout_trigger(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on timeout(WAIT_TIME) ()
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert isinstance(trans.trigger, TimeoutTrigger)
        assert trans.trigger.parameter == "WAIT_TIME"

    def test_transition_with_guard(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto when count > 0 ()
        )
        """)
        trans = schema.actors[0].transitions[0]
        assert trans.guard is not None


class TestPEGActions:
    """Action parsing tests."""

    def test_store_fields(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 on MSG (
                store x, y, z
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, StoreAction)
        assert action.fields == ["x", "y", "z"]

    def test_store_assign(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                STORE(key, value)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, StoreAction)
        assert "key" in action.assignments

    def test_assignment_action(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                result = HASH(data)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, ComputeAction)
        assert action.name == "result"

    def test_send_action(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                SEND(target, MSG)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, SendAction)
        assert action.message == "MSG"

    def test_broadcast_action(self):
        schema = parse("""
        actor A (
            state S1 initial
            state S2 terminal
            S1 -> S2 auto (
                BROADCAST(witnesses, MSG)
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert isinstance(action, BroadcastAction)


class TestPEGFunctions:
    """Function parsing tests."""

    def test_simple_function(self):
        schema = parse("""
        function add(a uint, b uint) -> uint (
            return a + b
        )
        """)
        assert len(schema.functions) == 1
        func = schema.functions[0]
        assert func.name == "add"
        assert len(func.params) == 2

    def test_native_function(self):
        schema = parse("""
        native function check(x string) -> bool "lib.check"
        """)
        func = schema.functions[0]
        assert func.is_native is True
        assert func.library_path == "lib.check"


class TestPEGExpressions:
    """Expression parsing tests."""

    def test_binary_operations(self):
        schema = parse("""
        actor A (
            state S initial
            state E terminal
            S -> E auto when a + b * c > 10 ()
        )
        """)
        guard = schema.actors[0].transitions[0].guard
        assert isinstance(guard, BinaryExpr)

    def test_function_call(self):
        schema = parse("""
        actor A (
            state S initial
            state E terminal
            S -> E auto when HASH(data) != null ()
        )
        """)
        guard = schema.actors[0].transitions[0].guard
        assert isinstance(guard, BinaryExpr)

    def test_field_access(self):
        schema = parse("""
        actor A (
            state S initial
            state E terminal
            S -> E auto (
                result = message.sender
            )
        )
        """)
        action = schema.actors[0].transitions[0].actions[0]
        assert action.name == "result"


class TestPEGTypes:
    """Type parsing tests."""

    def test_simple_type(self):
        schema = parse("""
        message M from A to [B] (
            value uint
        )
        """)
        field = schema.messages[0].fields[0]
        assert isinstance(field.type, SimpleType)
        assert field.type.name == "uint"

    def test_list_type(self):
        schema = parse("""
        message M from A to [B] (
            items list<uint>
        )
        """)
        field = schema.messages[0].fields[0]
        assert isinstance(field.type, ListType)

    def test_map_type(self):
        schema = parse("""
        message M from A to [B] (
            data map<string, uint>
        )
        """)
        field = schema.messages[0].fields[0]
        assert isinstance(field.type, MapType)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
