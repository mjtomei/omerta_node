"""Tests for DSL semantic validation."""

import pytest
import sys
sys.path.insert(0, str(__file__).rsplit('/tests/', 1)[0])

from dsl_ast import (
    Schema, ActorDecl, StateDecl, Transition, FunctionDecl, FunctionParam,
    MessageDecl, BlockDecl, EnumDecl, EnumValue, Field,
    StoreAction, SendAction, BroadcastAction, AppendBlockAction,
    AssignmentStmt, ReturnStmt, FunctionCallExpr, Identifier,
)
from dsl_validate import (
    validate_schema, validate_actor, validate_function, SchemaContext,
    ValidationResult, ValidationError,
)


class TestValidationResult:
    """Test ValidationResult class."""

    def test_empty_result(self):
        result = ValidationResult()
        assert not result.has_errors
        assert not result.has_warnings

    def test_add_error(self):
        result = ValidationResult()
        result.add_error("test error", line=10)
        assert result.has_errors
        assert len(result.errors) == 1
        assert result.errors[0].message == "test error"
        assert result.errors[0].line == 10

    def test_add_warning(self):
        result = ValidationResult()
        result.add_warning("test warning", line=5)
        assert result.has_warnings
        assert len(result.warnings) == 1

    def test_merge(self):
        r1 = ValidationResult()
        r1.add_error("error1")
        r1.add_warning("warning1")

        r2 = ValidationResult()
        r2.add_error("error2")

        r1.merge(r2)
        assert len(r1.errors) == 2
        assert len(r1.warnings) == 1


class TestActorValidation:
    """Test actor-level validation."""

    def test_missing_initial_state(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="RUNNING"),
                StateDecl(name="DONE", terminal=True),
            ],
            transitions=[],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("no initial state" in e.message for e in result.errors)

    def test_multiple_initial_states(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="READY", initial=True),
            ],
            transitions=[],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("multiple initial states" in e.message for e in result.errors)

    def test_no_terminal_states_warning(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="RUNNING"),
            ],
            transitions=[],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_warnings
        assert any("no terminal states" in w.message for w in result.warnings)

    def test_duplicate_states(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="IDLE"),  # Duplicate
            ],
            transitions=[],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("Duplicate state" in e.message for e in result.errors)

    def test_unreachable_state_warning(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="RUNNING"),
                StateDecl(name="ORPHAN"),  # Unreachable
                StateDecl(name="DONE", terminal=True),
            ],
            transitions=[
                Transition(from_state="IDLE", to_state="RUNNING", auto=True),
                Transition(from_state="RUNNING", to_state="DONE", auto=True),
            ],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_warnings
        assert any("unreachable" in w.message and "ORPHAN" in w.message
                   for w in result.warnings)


class TestTransitionValidation:
    """Test transition-level validation."""

    def test_unknown_from_state(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
            ],
            transitions=[
                Transition(from_state="UNKNOWN", to_state="IDLE", auto=True),
            ],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("unknown state 'UNKNOWN'" in e.message for e in result.errors)

    def test_unknown_to_state(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
            ],
            transitions=[
                Transition(from_state="IDLE", to_state="UNKNOWN", auto=True),
            ],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("unknown target state 'UNKNOWN'" in e.message for e in result.errors)

    def test_unknown_message_trigger(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="DONE", terminal=True),
            ],
            transitions=[
                Transition(from_state="IDLE", to_state="DONE", trigger="UNKNOWN_MSG"),
            ],
        )
        # No messages defined
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("neither a message nor a declared trigger" in e.message
                   for e in result.errors)

    def test_valid_message_trigger(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="DONE", terminal=True),
            ],
            transitions=[
                Transition(from_state="IDLE", to_state="DONE", trigger="REQUEST"),
            ],
        )
        # REQUEST is defined as a message
        ctx = SchemaContext()
        ctx.message_names = {"REQUEST"}
        result = validate_actor(actor, ctx)
        assert not result.has_errors


class TestActionValidation:
    """Test action-level validation."""

    def test_send_unknown_message(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="DONE", terminal=True),
            ],
            transitions=[
                Transition(
                    from_state="IDLE",
                    to_state="DONE",
                    auto=True,
                    actions=[SendAction(message="UNKNOWN_MSG", target="target")],
                ),
            ],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("SEND references unknown message" in e.message for e in result.errors)

    def test_broadcast_unknown_message(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="DONE", terminal=True),
            ],
            transitions=[
                Transition(
                    from_state="IDLE",
                    to_state="DONE",
                    auto=True,
                    actions=[BroadcastAction(message="UNKNOWN_MSG", target_list="targets")],
                ),
            ],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("BROADCAST references unknown message" in e.message for e in result.errors)

    def test_append_unknown_block(self):
        actor = ActorDecl(
            name="TestActor",
            states=[
                StateDecl(name="IDLE", initial=True),
                StateDecl(name="DONE", terminal=True),
            ],
            transitions=[
                Transition(
                    from_state="IDLE",
                    to_state="DONE",
                    auto=True,
                    actions=[AppendBlockAction(block_type="UNKNOWN_BLOCK")],
                ),
            ],
        )
        result = validate_actor(actor, SchemaContext())
        assert result.has_errors
        assert any("APPEND references unknown block type" in e.message for e in result.errors)


class TestFunctionPurity:
    """Test function purity validation."""

    def test_pure_function(self):
        func = FunctionDecl(
            name="add",
            params=[FunctionParam("a", "int"), FunctionParam("b", "int")],
            return_type="int",
            statements=[
                ReturnStmt(expression=Identifier(name="result")),
            ],
        )
        ctx = SchemaContext()
        result = validate_function(func, ctx)
        assert not result.has_errors

    def test_function_with_store_in_string(self):
        func = FunctionDecl(
            name="bad_func",
            params=[],
            return_type="void",
            statements=[
                AssignmentStmt(name="x", expression="STORE(x, 1)"),
            ],
        )
        ctx = SchemaContext()
        result = validate_function(func, ctx)
        assert result.has_errors
        assert any("impure operation 'STORE'" in e.message for e in result.errors)

    def test_function_with_send_call(self):
        func = FunctionDecl(
            name="bad_func",
            params=[],
            return_type="void",
            statements=[
                AssignmentStmt(
                    name="x",
                    expression=FunctionCallExpr(name="SEND", args=[]),
                ),
            ],
        )
        ctx = SchemaContext()
        result = validate_function(func, ctx)
        assert result.has_errors
        assert any("impure operation 'SEND'" in e.message for e in result.errors)

    def test_native_function_skipped(self):
        func = FunctionDecl(
            name="native_func",
            params=[],
            return_type="int",
            is_native=True,
            library_path="some.module",
        )
        ctx = SchemaContext()
        result = validate_function(func, ctx)
        assert not result.has_errors


class TestObjectTypeValidation:
    """Test object type validation."""

    def test_object_type_in_message(self):
        schema = Schema(
            messages=[
                MessageDecl(
                    name="TestMsg",
                    sender="Actor",
                    recipients=["Target"],
                    signed=False,
                    fields=[Field(name="data", type="object")],
                ),
            ],
        )
        result = validate_schema(schema)
        assert result.has_errors
        assert any("type 'object' not allowed" in e.message for e in result.errors)

    def test_list_object_type_in_actor_store(self):
        schema = Schema(
            actors=[
                ActorDecl(
                    name="TestActor",
                    store=[Field(name="items", type="list<object>")],
                    states=[StateDecl(name="IDLE", initial=True, terminal=True)],
                ),
            ],
        )
        result = validate_schema(schema)
        assert result.has_errors
        assert any("type 'list<object>' not allowed" in e.message for e in result.errors)


class TestFullSchemaValidation:
    """Test full schema validation."""

    def test_valid_minimal_schema(self):
        schema = Schema(
            actors=[
                ActorDecl(
                    name="TestActor",
                    states=[
                        StateDecl(name="IDLE", initial=True),
                        StateDecl(name="DONE", terminal=True),
                    ],
                    transitions=[
                        Transition(from_state="IDLE", to_state="DONE", auto=True),
                    ],
                ),
            ],
        )
        result = validate_schema(schema)
        assert not result.has_errors

    def test_schema_with_messages_and_blocks(self):
        schema = Schema(
            messages=[
                MessageDecl(name="REQUEST", sender="Client", recipients=["Server"], signed=False,
                           fields=[Field(name="id", type="string")]),
                MessageDecl(name="RESPONSE", sender="Server", recipients=["Client"], signed=False,
                           fields=[Field(name="status", type="string")]),
            ],
            blocks=[
                BlockDecl(name="COMMIT", appended_by=["Server"], fields=[Field(name="data", type="hash")]),
            ],
            actors=[
                ActorDecl(
                    name="TestActor",
                    states=[
                        StateDecl(name="IDLE", initial=True),
                        StateDecl(name="DONE", terminal=True),
                    ],
                    transitions=[
                        Transition(
                            from_state="IDLE",
                            to_state="DONE",
                            trigger="REQUEST",
                            actions=[
                                SendAction(message="RESPONSE", target="sender"),
                                AppendBlockAction(block_type="COMMIT"),
                            ],
                        ),
                    ],
                ),
            ],
        )
        result = validate_schema(schema)
        assert not result.has_errors


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
