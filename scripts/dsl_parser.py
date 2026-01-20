"""
Parser for the transaction DSL.

Parses a token stream into an AST.
"""

from typing import List, Optional, Set

try:
    from .dsl_lexer import Token, TokenType, tokenize, LexerError
    from .dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, TriggerParam, StateDecl,
        Transition, OnGuardFail, StoreAction, ComputeAction, LookupAction, SendAction,
        BroadcastAction, AppendAction, AppendBlockAction, FunctionDecl, FunctionParam, Action,
        AssignmentStmt, ReturnStmt, ForStmt, IfStmt, FunctionStatement,
        # Expression AST
        Expr, Identifier, Literal, BinaryExpr, UnaryExpr, IfExpr,
        FunctionCallExpr, FieldAccessExpr, DynamicFieldAccessExpr, IndexAccessExpr,
        LambdaExpr, StructLiteralExpr, ListLiteralExpr, EnumRefExpr,
        BinaryOperator, UnaryOperator,
        # Type AST
        TypeExpr, SimpleType, ListType, MapType,
        # Trigger AST
        TriggerExpr, MessageTrigger, TimeoutTrigger, NamedTrigger
    )
except ImportError:
    from dsl_lexer import Token, TokenType, tokenize, LexerError
    from dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, TriggerParam, StateDecl,
        Transition, OnGuardFail, StoreAction, ComputeAction, LookupAction, SendAction,
        BroadcastAction, AppendAction, AppendBlockAction, FunctionDecl, FunctionParam, Action,
        AssignmentStmt, ReturnStmt, ForStmt, IfStmt, FunctionStatement,
        # Expression AST
        Expr, Identifier, Literal, BinaryExpr, UnaryExpr, IfExpr,
        FunctionCallExpr, FieldAccessExpr, DynamicFieldAccessExpr, IndexAccessExpr,
        LambdaExpr, StructLiteralExpr, ListLiteralExpr, EnumRefExpr,
        BinaryOperator, UnaryOperator,
        # Type AST
        TypeExpr, SimpleType, ListType, MapType,
        # Trigger AST
        TriggerExpr, MessageTrigger, TimeoutTrigger, NamedTrigger
    )


class ParseError(Exception):
    """Raised when parser encounters invalid syntax."""
    def __init__(self, message: str, token: Token):
        self.token = token
        super().__init__(f"Line {token.line}, column {token.column}: {message}")


def _type_to_str(type_expr: TypeExpr) -> str:
    """Convert a TypeExpr back to string representation."""
    if isinstance(type_expr, SimpleType):
        return type_expr.name
    elif isinstance(type_expr, ListType):
        return f"list<{_type_to_str(type_expr.element_type)}>"
    elif isinstance(type_expr, MapType):
        return f"map<{_type_to_str(type_expr.key_type)}, {_type_to_str(type_expr.value_type)}>"
    else:
        return str(type_expr)


# Side-effect operations that are only allowed in transition actions, not function bodies
SIDE_EFFECT_OPERATIONS = {'SEND', 'BROADCAST', 'APPEND', 'APPEND_BLOCK'}


def _find_side_effects_in_expr(expr: Expr) -> Optional[str]:
    """Find side-effect function calls in an expression AST.

    Returns the name of the side-effect operation if found, None otherwise.
    """
    if isinstance(expr, FunctionCallExpr):
        if expr.name.upper() in SIDE_EFFECT_OPERATIONS:
            return expr.name.upper()
        # Check arguments
        for arg in expr.args:
            result = _find_side_effects_in_expr(arg)
            if result:
                return result
    elif isinstance(expr, BinaryExpr):
        result = _find_side_effects_in_expr(expr.left)
        if result:
            return result
        return _find_side_effects_in_expr(expr.right)
    elif isinstance(expr, UnaryExpr):
        return _find_side_effects_in_expr(expr.operand)
    elif isinstance(expr, IfExpr):
        result = _find_side_effects_in_expr(expr.condition)
        if result:
            return result
        result = _find_side_effects_in_expr(expr.then_expr)
        if result:
            return result
        return _find_side_effects_in_expr(expr.else_expr)
    elif isinstance(expr, FieldAccessExpr):
        return _find_side_effects_in_expr(expr.object)
    elif isinstance(expr, DynamicFieldAccessExpr):
        result = _find_side_effects_in_expr(expr.object)
        if result:
            return result
        return _find_side_effects_in_expr(expr.key_expr)
    elif isinstance(expr, IndexAccessExpr):
        result = _find_side_effects_in_expr(expr.object)
        if result:
            return result
        return _find_side_effects_in_expr(expr.index)
    elif isinstance(expr, LambdaExpr):
        return _find_side_effects_in_expr(expr.body)
    elif isinstance(expr, StructLiteralExpr):
        for value in expr.fields.values():
            result = _find_side_effects_in_expr(value)
            if result:
                return result
        if expr.spread:
            return _find_side_effects_in_expr(expr.spread)
    elif isinstance(expr, ListLiteralExpr):
        for elem in expr.elements:
            result = _find_side_effects_in_expr(elem)
            if result:
                return result
    # Identifier, Literal, EnumRefExpr have no sub-expressions
    return None


def _check_function_purity(statements: List[FunctionStatement], func_name: str, line: int, col: int) -> None:
    """Check that function body contains no side-effect operations.

    Functions must be pure - side effects (SEND, BROADCAST, APPEND, APPEND_BLOCK)
    are only allowed in transition actions.

    Raises ParseError if side effects are found.
    """
    for stmt in statements:
        # Get expression(s) to check from this statement
        expressions_to_check = []
        if isinstance(stmt, AssignmentStmt):
            expressions_to_check.append(stmt.expression)
        elif isinstance(stmt, ReturnStmt):
            expressions_to_check.append(stmt.expression)
        elif isinstance(stmt, ForStmt):
            expressions_to_check.append(stmt.iterable)
            # Recursively check body
            _check_function_purity(stmt.body, func_name, line, col)
        elif isinstance(stmt, IfStmt):
            expressions_to_check.append(stmt.condition)
            # Recursively check both branches
            _check_function_purity(stmt.then_body, func_name, line, col)
            _check_function_purity(stmt.else_body, func_name, line, col)

        # Check each expression for side-effect function calls
        for expr in expressions_to_check:
            # Handle both string (legacy) and Expr AST
            if isinstance(expr, str):
                import re
                for op in SIDE_EFFECT_OPERATIONS:
                    if re.search(rf'\b{op}\s*\(', expr, re.IGNORECASE):
                        raise ParseError(
                            f"Side effect '{op}' not allowed in function '{func_name}'. "
                            f"Side effects are only allowed in transition actions.",
                            Token(TokenType.IDENTIFIER, op, line, col)
                        )
            else:
                side_effect = _find_side_effects_in_expr(expr)
                if side_effect:
                    raise ParseError(
                        f"Side effect '{side_effect}' not allowed in function '{func_name}'. "
                        f"Side effects are only allowed in transition actions.",
                        Token(TokenType.IDENTIFIER, side_effect, line, col)
                    )


class Parser:
    """Recursive descent parser for the transaction DSL."""

    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0
        self._grouping_depth = 0  # Track nesting inside (), [], {}

    def parse(self) -> Schema:
        """Parse the token stream into a Schema AST."""
        schema = Schema()

        while not self._at_end():
            self._skip_whitespace()
            if self._at_end():
                break

            if self._check(TokenType.TRANSACTION):
                schema.transaction = self._parse_transaction()
            elif self._check(TokenType.IMPORTS):
                schema.imports.append(self._parse_import())
            elif self._check(TokenType.PARAMETERS):
                schema.parameters = self._parse_parameters()
            elif self._check(TokenType.ENUM):
                schema.enums.append(self._parse_enum())
            elif self._check(TokenType.MESSAGE):
                schema.messages.append(self._parse_message())
            elif self._check(TokenType.BLOCK):
                schema.blocks.append(self._parse_block())
            elif self._check(TokenType.ACTOR):
                schema.actors.append(self._parse_actor())
            elif self._check(TokenType.FUNCTION):
                schema.functions.append(self._parse_function())
            elif self._check(TokenType.NATIVE):
                schema.functions.append(self._parse_native_function())
            elif self._check(TokenType.COMMENT):
                self._advance()  # Skip comments
            elif self._check(TokenType.NEWLINE):
                self._advance()  # Skip blank lines
            else:
                raise ParseError(f"Unexpected token: {self._peek().value}", self._peek())

        return schema

    # =========================================================================
    # Helper methods
    # =========================================================================

    def _at_end(self) -> bool:
        return self._peek().type == TokenType.EOF

    def _peek(self, offset: int = 0) -> Token:
        pos = self.pos + offset
        if pos >= len(self.tokens):
            return self.tokens[-1]  # EOF
        return self.tokens[pos]

    def _advance(self) -> Token:
        token = self.tokens[self.pos]
        if not self._at_end():
            self.pos += 1
        return token

    def _check(self, token_type: TokenType) -> bool:
        return self._peek().type == token_type

    def _match(self, *token_types: TokenType) -> bool:
        for tt in token_types:
            if self._check(tt):
                self._advance()
                return True
        return False

    def _expect(self, token_type: TokenType, message: str = None) -> Token:
        if self._check(token_type):
            return self._advance()
        msg = message or f"Expected {token_type.name}"
        raise ParseError(msg, self._peek())

    def _skip_whitespace(self):
        """Skip newlines and comments."""
        while self._match(TokenType.NEWLINE, TokenType.COMMENT):
            pass

    def _skip_expr_newlines(self):
        """Skip newlines/comments when inside grouping constructs (parens, brackets, braces).

        This allows multiline expressions inside grouping constructs while preserving
        newlines as statement separators at the top level.
        """
        if self._grouping_depth > 0:
            self._skip_whitespace()

    def _skip_to_newline(self):
        """Skip to end of line (for inline comments)."""
        while not self._at_end() and not self._check(TokenType.NEWLINE):
            if self._check(TokenType.COMMENT):
                self._advance()
                break
            self._advance()

    # =========================================================================
    # Top-level declarations
    # =========================================================================

    def _parse_transaction(self) -> Transaction:
        """Parse: transaction ID STRING STRING?"""
        token = self._expect(TokenType.TRANSACTION)
        # ID can be either identifier or number
        if self._check(TokenType.NUMBER):
            tx_id = self._advance().value
        elif self._check(TokenType.IDENTIFIER):
            tx_id = self._advance().value
        else:
            raise ParseError("Expected transaction ID", self._peek())
        name = self._expect(TokenType.STRING, "Expected transaction name").value
        # Optional description
        description = None
        if self._check(TokenType.STRING):
            description = self._advance().value
        return Transaction(id=tx_id, name=name, description=description,
                          line=token.line, column=token.column)

    def _parse_import(self) -> Import:
        """Parse: imports path/to/file"""
        token = self._expect(TokenType.IMPORTS)
        # Path is a sequence of identifiers separated by /
        path_parts = [self._expect(TokenType.IDENTIFIER, "Expected import path").value]
        while self._match(TokenType.SLASH):
            path_parts.append(self._expect(TokenType.IDENTIFIER).value)
        return Import(path='/'.join(path_parts), line=token.line, column=token.column)

    def _parse_parameters(self) -> List[Parameter]:
        """Parse: parameters ( ... )"""
        self._expect(TokenType.PARAMETERS)
        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' after 'parameters'")

        params = []
        self._skip_whitespace()

        while not self._check(TokenType.RPAREN) and not self._at_end():
            param = self._parse_parameter()
            if param:
                params.append(param)
            self._skip_whitespace()

        self._expect(TokenType.RPAREN, "Expected ')' to close parameters block")
        return params

    def _parse_parameter(self) -> Optional[Parameter]:
        """Parse: NAME = value unit? "description"?"""
        if self._check(TokenType.COMMENT):
            self._advance()
            return None

        token = self._expect(TokenType.IDENTIFIER, "Expected parameter name")
        name = token.value
        self._expect(TokenType.EQUALS, "Expected '=' after parameter name")

        # Value can be number or identifier
        if self._check(TokenType.NUMBER):
            value_str = self._advance().value
            value = float(value_str) if '.' in value_str else int(value_str)
        else:
            value = self._expect(TokenType.IDENTIFIER, "Expected parameter value").value

        # Optional unit
        unit = None
        if self._check(TokenType.IDENTIFIER):
            unit = self._advance().value

        # Optional description
        description = None
        if self._check(TokenType.STRING):
            description = self._advance().value

        return Parameter(
            name=name, value=value, unit=unit, description=description,
            line=token.line, column=token.column
        )

    def _parse_enum(self) -> EnumDecl:
        """Parse: enum NAME "description"? ( VALUE VALUE ... )"""
        token = self._expect(TokenType.ENUM)
        name = self._expect(TokenType.IDENTIFIER, "Expected enum name").value
        # Optional description
        description = None
        if self._check(TokenType.STRING):
            description = self._advance().value
        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' after enum name")

        values = []
        self._skip_whitespace()

        while not self._check(TokenType.RPAREN) and not self._at_end():
            if self._check(TokenType.COMMENT):
                self._advance()
                self._skip_whitespace()
                continue

            val_token = self._expect(TokenType.IDENTIFIER, "Expected enum value")
            comment = None
            if self._check(TokenType.COMMENT):
                comment = self._advance().value[1:].strip()  # Remove # prefix

            values.append(EnumValue(name=val_token.value, comment=comment,
                                   line=val_token.line, column=val_token.column))
            self._skip_whitespace()

        self._expect(TokenType.RPAREN, "Expected ')' to close enum")
        return EnumDecl(name=name, description=description, values=values,
                       line=token.line, column=token.column)

    def _parse_message(self) -> MessageDecl:
        """Parse: message NAME from SENDER to [RECIPIENTS] signed? ( fields )"""
        token = self._expect(TokenType.MESSAGE)
        self._skip_whitespace()
        name = self._expect(TokenType.IDENTIFIER, "Expected message name").value

        self._skip_whitespace()
        self._expect(TokenType.FROM, "Expected 'from'")
        self._skip_whitespace()
        sender = self._expect(TokenType.IDENTIFIER, "Expected sender").value

        self._skip_whitespace()
        self._expect(TokenType.TO, "Expected 'to'")
        self._skip_whitespace()
        self._expect(TokenType.LBRACKET, "Expected '[' before recipients")
        self._skip_whitespace()
        recipients = self._parse_identifier_list()
        self._skip_whitespace()
        self._expect(TokenType.RBRACKET, "Expected ']' after recipients")

        self._skip_whitespace()
        signed = self._match(TokenType.SIGNED)

        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' for message fields")
        fields = self._parse_fields()
        self._expect(TokenType.RPAREN, "Expected ')' to close message")

        return MessageDecl(
            name=name, sender=sender, recipients=recipients, signed=signed,
            fields=fields, line=token.line, column=token.column
        )

    def _parse_block(self) -> BlockDecl:
        """Parse: block NAME by [ACTORS] ( fields )"""
        token = self._expect(TokenType.BLOCK)
        self._skip_whitespace()
        name = self._expect(TokenType.IDENTIFIER, "Expected block name").value

        self._skip_whitespace()
        self._expect(TokenType.BY, "Expected 'by'")
        self._skip_whitespace()
        self._expect(TokenType.LBRACKET, "Expected '[' before actors")
        self._skip_whitespace()
        appended_by = self._parse_identifier_list()
        self._skip_whitespace()
        self._expect(TokenType.RBRACKET, "Expected ']' after actors")

        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' for block fields")
        fields = self._parse_fields()
        self._expect(TokenType.RPAREN, "Expected ')' to close block")

        return BlockDecl(
            name=name, appended_by=appended_by, fields=fields,
            line=token.line, column=token.column
        )

    # =========================================================================
    # Actor parsing
    # =========================================================================

    def _parse_actor(self) -> ActorDecl:
        """Parse: actor NAME "description"? ( ... )"""
        token = self._expect(TokenType.ACTOR)
        name = self._expect(TokenType.IDENTIFIER, "Expected actor name").value

        description = None
        if self._check(TokenType.STRING):
            description = self._advance().value

        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' to start actor body")

        actor = ActorDecl(name=name, description=description,
                         line=token.line, column=token.column)

        self._skip_whitespace()
        while not self._check(TokenType.RPAREN) and not self._at_end():
            if self._check(TokenType.STORE):
                actor.store = self._parse_store_block()
            elif self._check(TokenType.TRIGGER):
                actor.triggers.append(self._parse_trigger())
            elif self._check(TokenType.STATE):
                actor.states.append(self._parse_state())
            elif self._check(TokenType.IDENTIFIER):
                # Could be a transition: STATE -> STATE ...
                actor.transitions.append(self._parse_transition())
            elif self._check(TokenType.COMMENT):
                self._advance()
            else:
                raise ParseError(f"Unexpected token in actor: {self._peek().value}", self._peek())
            self._skip_whitespace()

        self._expect(TokenType.RPAREN, "Expected ')' to close actor")
        return actor

    def _parse_store_block(self) -> List[Field]:
        """Parse: store ( field field ... )"""
        self._expect(TokenType.STORE)
        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' after 'store'")
        fields = self._parse_fields()
        self._expect(TokenType.RPAREN, "Expected ')' to close store")
        return fields

    def _parse_trigger(self) -> TriggerDecl:
        """Parse: trigger NAME(param1 type1, param2 type2) in [STATES] "description"?"""
        token = self._expect(TokenType.TRIGGER)
        name = self._expect(TokenType.IDENTIFIER, "Expected trigger name").value

        # Parse typed parameters
        self._expect(TokenType.LPAREN, "Expected '(' for trigger params")
        params = []
        if not self._check(TokenType.RPAREN):
            params = self._parse_trigger_params()
        self._expect(TokenType.RPAREN, "Expected ')' after trigger params")

        self._skip_whitespace()
        self._expect(TokenType.IN, "Expected 'in'")
        self._expect(TokenType.LBRACKET, "Expected '[' before allowed states")
        allowed_in = self._parse_identifier_list()
        self._expect(TokenType.RBRACKET, "Expected ']' after allowed states")

        description = None
        if self._check(TokenType.STRING):
            description = self._advance().value

        return TriggerDecl(
            name=name, params=params, allowed_in=allowed_in,
            description=description, line=token.line, column=token.column
        )

    def _parse_trigger_params(self) -> List[TriggerParam]:
        """Parse trigger parameters: name type, name type, ..."""
        params = []

        self._skip_whitespace()  # Allow leading whitespace
        while True:
            param_token = self._expect(TokenType.IDENTIFIER, "Expected parameter name")
            param_name = param_token.value
            param_type = self._parse_type()
            params.append(TriggerParam(name=param_name, type=param_type,
                                       line=param_token.line, column=param_token.column))

            self._skip_whitespace()  # Allow whitespace before comma
            if not self._match(TokenType.COMMA):
                break
            self._skip_whitespace()  # Allow whitespace after comma

        return params

    def _parse_state(self) -> StateDecl:
        """Parse: state NAME (initial|terminal)? "description"?"""
        token = self._expect(TokenType.STATE)
        name = self._expect(TokenType.IDENTIFIER, "Expected state name").value

        initial = self._match(TokenType.INITIAL)
        terminal = self._match(TokenType.TERMINAL)

        description = None
        if self._check(TokenType.STRING):
            description = self._advance().value

        return StateDecl(
            name=name, initial=initial, terminal=terminal,
            description=description, line=token.line, column=token.column
        )

    def _parse_transition(self) -> Transition:
        """Parse: FROM -> TO (on TRIGGER | auto) (when GUARD)? ( actions )? (else -> STATE ( actions ))?"""
        token = self._peek()
        from_state = self._expect(TokenType.IDENTIFIER, "Expected source state").value
        self._skip_whitespace()  # Allow whitespace before ->
        self._expect(TokenType.ARROW, "Expected '->'")
        self._skip_whitespace()  # Allow whitespace after ->
        to_state = self._expect(TokenType.IDENTIFIER, "Expected target state").value

        # Trigger or auto
        self._skip_whitespace()  # Allow whitespace before on/auto
        trigger = None
        auto = False
        if self._match(TokenType.ON):
            self._skip_whitespace()  # Allow whitespace after on
            # Could be a message name, trigger name, or timeout(...)
            trigger = self._parse_trigger_spec()
        elif self._match(TokenType.AUTO):
            auto = True
        else:
            raise ParseError("Expected 'on' or 'auto' after transition", self._peek())

        # Optional guard
        self._skip_whitespace()  # Allow whitespace before when
        guard = None
        if self._match(TokenType.WHEN):
            self._skip_whitespace()  # Allow whitespace after when
            guard = self._parse_guard_expression()

        # Optional actions block
        actions = []
        self._skip_whitespace()
        if self._check(TokenType.LPAREN):
            self._advance()
            actions = self._parse_actions()
            self._expect(TokenType.RPAREN, "Expected ')' to close actions")

        # Optional else clause for guard failure
        on_guard_fail = None
        self._skip_whitespace()
        if self._match(TokenType.ELSE):
            on_guard_fail = self._parse_on_guard_fail()

        return Transition(
            from_state=from_state, to_state=to_state, trigger=trigger,
            auto=auto, guard=guard, actions=actions, on_guard_fail=on_guard_fail,
            line=token.line, column=token.column
        )

    def _parse_on_guard_fail(self) -> OnGuardFail:
        """Parse: else -> STATE ( actions )"""
        token = self._peek()
        self._skip_whitespace()  # Allow whitespace before ->
        self._expect(TokenType.ARROW, "Expected '->' after 'else'")
        self._skip_whitespace()  # Allow whitespace after ->
        target = self._expect(TokenType.IDENTIFIER, "Expected target state for guard failure").value

        # Optional actions block
        actions = []
        self._skip_whitespace()
        if self._check(TokenType.LPAREN):
            self._advance()
            actions = self._parse_actions()
            self._expect(TokenType.RPAREN, "Expected ')' to close actions")

        return OnGuardFail(target=target, actions=actions,
                         line=token.line, column=token.column)

    def _parse_trigger_spec(self) -> TriggerExpr:
        """Parse trigger specification: NAME or timeout(PARAM)"""
        token = self._expect(TokenType.IDENTIFIER, "Expected trigger name")
        name = token.value

        # Check for timeout(PARAM) syntax - only if name is 'timeout'
        if name.lower() == 'timeout' and self._check(TokenType.LPAREN):
            self._advance()
            param = self._expect(TokenType.IDENTIFIER, "Expected timeout parameter").value
            self._expect(TokenType.RPAREN, "Expected ')' after timeout parameter")
            return TimeoutTrigger(param, token.line, token.column)

        # Check if this is a message trigger (uppercase convention) or named trigger
        # We'll use a heuristic: all-uppercase names are message triggers
        if name.isupper():
            return MessageTrigger(name, token.line, token.column)
        else:
            return NamedTrigger(name, token.line, token.column)

    # =========================================================================
    # Actions parsing
    # =========================================================================

    def _parse_actions(self) -> List[Action]:
        """Parse a list of actions inside ( )."""
        actions = []
        self._skip_whitespace()

        while not self._check(TokenType.RPAREN) and not self._at_end():
            if self._check(TokenType.STORE):
                actions.append(self._parse_store_action())
            elif self._check(TokenType.COMPUTE):
                actions.append(self._parse_compute_action())
            elif self._check(TokenType.LOOKUP):
                actions.append(self._parse_lookup_action())
            elif self._check(TokenType.SEND):
                actions.append(self._parse_send_action())
            elif self._check(TokenType.BROADCAST):
                actions.append(self._parse_broadcast_action())
            elif self._check(TokenType.APPEND_BLOCK):
                actions.append(self._parse_append_block_action())
            elif self._check(TokenType.APPEND):
                actions.append(self._parse_append_action())
            elif self._check(TokenType.COMMENT):
                self._advance()
            else:
                raise ParseError(f"Unexpected action: {self._peek().value}", self._peek())
            self._skip_whitespace()

        return actions

    def _parse_store_action(self) -> StoreAction:
        """Parse: store x, y, z  OR  STORE(key, value)"""
        token = self._expect(TokenType.STORE)
        action = StoreAction(line=token.line, column=token.column)

        # Check for function-call style: STORE(key, value)
        if self._check(TokenType.LPAREN):
            self._advance()  # consume (
            self._skip_whitespace()
            key = self._expect(TokenType.IDENTIFIER, "Expected key name").value
            self._skip_whitespace()
            self._expect(TokenType.COMMA, "Expected ',' after key")
            self._skip_whitespace()
            value = self._parse_expression()
            self._skip_whitespace()
            self._expect(TokenType.RPAREN, "Expected ')' to close STORE")
            action.assignments[key] = value
            return action

        # Legacy style: store x, y, z (field extraction from message/trigger)
        first_id = self._expect(TokenType.IDENTIFIER, "Expected field name").value

        if self._match(TokenType.COMMA):
            # store x, y, z
            action.fields = [first_id]
            action.fields.extend(self._parse_identifier_list())
        else:
            # Just store x
            action.fields = [first_id]

        return action

    def _parse_compute_action(self) -> ComputeAction:
        """Parse: compute NAME = expr"""
        token = self._expect(TokenType.COMPUTE)
        name = self._expect(TokenType.IDENTIFIER, "Expected variable name").value
        self._expect(TokenType.EQUALS, "Expected '=' after variable name")
        expr = self._parse_expression()

        return ComputeAction(name=name, expression=expr,
                           line=token.line, column=token.column)

    def _parse_lookup_action(self) -> LookupAction:
        """Parse: lookup NAME = expr"""
        token = self._expect(TokenType.LOOKUP)
        name = self._expect(TokenType.IDENTIFIER, "Expected variable name").value
        self._expect(TokenType.EQUALS, "Expected '=' after variable name")
        expr = self._parse_expression()

        return LookupAction(name=name, expression=expr,
                           line=token.line, column=token.column)

    def _parse_send_action(self) -> SendAction:
        """Parse: SEND(target, MESSAGE)"""
        token = self._expect(TokenType.SEND)
        self._expect(TokenType.LPAREN, "Expected '(' after SEND")
        self._skip_whitespace()
        target = self._parse_send_target()
        self._skip_whitespace()
        self._expect(TokenType.COMMA, "Expected ',' after target")
        self._skip_whitespace()
        message = self._expect(TokenType.IDENTIFIER, "Expected message name").value
        self._skip_whitespace()
        self._expect(TokenType.RPAREN, "Expected ')' to close SEND")

        return SendAction(message=message, target=target,
                         line=token.line, column=token.column)

    def _parse_broadcast_action(self) -> BroadcastAction:
        """Parse: BROADCAST(list, MESSAGE)"""
        token = self._expect(TokenType.BROADCAST)
        self._expect(TokenType.LPAREN, "Expected '(' after BROADCAST")
        self._skip_whitespace()
        target_list = self._expect(TokenType.IDENTIFIER, "Expected target list").value
        self._skip_whitespace()
        self._expect(TokenType.COMMA, "Expected ',' after target list")
        self._skip_whitespace()
        message = self._expect(TokenType.IDENTIFIER, "Expected message name").value
        self._skip_whitespace()
        self._expect(TokenType.RPAREN, "Expected ')' to close BROADCAST")

        return BroadcastAction(message=message, target_list=target_list,
                              line=token.line, column=token.column)

    def _parse_send_target(self) -> str:
        """Parse send target: identifier or dotted expression like message.sender"""
        # Allow MESSAGE token since "message.sender" is a common target
        if self._check(TokenType.MESSAGE):
            name = self._advance().value
        elif self._check(TokenType.IDENTIFIER):
            name = self._advance().value
        else:
            raise ParseError("Expected target", self._peek())

        # Handle dotted expressions like message.sender
        while self._check(TokenType.DOT):
            self._advance()  # consume the dot
            next_part = self._expect(TokenType.IDENTIFIER, "Expected identifier after dot").value
            name = f"{name}.{next_part}"

        return name

    def _parse_append_action(self) -> AppendAction:
        """Parse: APPEND(list, value) - for both list appends and chain appends (my_chain)"""
        token = self._expect(TokenType.APPEND)
        self._expect(TokenType.LPAREN, "Expected '(' after APPEND")
        self._skip_whitespace()
        list_name = self._expect(TokenType.IDENTIFIER, "Expected list name").value
        self._skip_whitespace()
        self._expect(TokenType.COMMA, "Expected ',' after list name")
        self._skip_whitespace()
        value = self._parse_expression()
        self._skip_whitespace()
        self._expect(TokenType.RPAREN, "Expected ')' to close APPEND")

        return AppendAction(list_name=list_name, value=value,
                           line=token.line, column=token.column)

    def _parse_append_block_action(self) -> AppendBlockAction:
        """Parse: append_block BLOCK_TYPE (legacy - kept for backwards compatibility)"""
        token = self._expect(TokenType.APPEND_BLOCK)
        block_type = self._expect(TokenType.IDENTIFIER, "Expected block type").value

        return AppendBlockAction(block_type=block_type,
                                line=token.line, column=token.column)

    # =========================================================================
    # Function parsing
    # =========================================================================

    def _parse_function(self) -> FunctionDecl:
        """Parse: function NAME(params) -> TYPE ( body )"""
        token = self._expect(TokenType.FUNCTION)
        name = self._expect(TokenType.IDENTIFIER, "Expected function name").value

        # Parameters
        self._expect(TokenType.LPAREN, "Expected '(' for function params")
        params = []
        if not self._check(TokenType.RPAREN):
            params = self._parse_function_params()
        self._expect(TokenType.RPAREN, "Expected ')' after function params")

        # Return type
        self._expect(TokenType.ARROW, "Expected '->' for return type")
        return_type = self._parse_type()

        # Body - parse into statements
        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' for function body")
        statements = self._parse_function_body_statements()
        self._expect(TokenType.RPAREN, "Expected ')' to close function")

        # Validate function purity - no side effects allowed
        _check_function_purity(statements, name, token.line, token.column)

        return FunctionDecl(
            name=name, params=params, return_type=return_type,
            statements=statements,
            line=token.line, column=token.column
        )

    def _parse_native_function(self) -> FunctionDecl:
        """Parse: native function NAME(params) -> TYPE "library.path" """
        token = self._expect(TokenType.NATIVE)
        self._expect(TokenType.FUNCTION, "Expected 'function' after 'native'")
        name = self._expect(TokenType.IDENTIFIER, "Expected function name").value

        # Parameters
        self._expect(TokenType.LPAREN, "Expected '(' for function params")
        params = []
        if not self._check(TokenType.RPAREN):
            params = self._parse_function_params()
        self._expect(TokenType.RPAREN, "Expected ')' after function params")

        # Return type
        self._expect(TokenType.ARROW, "Expected '->' for return type")
        return_type = self._parse_type()

        # Library path (string)
        self._skip_whitespace()
        library_path = self._expect(TokenType.STRING, "Expected library path string").value

        return FunctionDecl(
            name=name, params=params, return_type=return_type, body="",
            is_native=True, library_path=library_path,
            line=token.line, column=token.column
        )

    def _parse_function_params(self) -> List[FunctionParam]:
        """Parse function parameters: name type, name type, ..."""
        params = []

        self._skip_whitespace()  # Allow leading whitespace
        while True:
            name = self._expect(TokenType.IDENTIFIER, "Expected parameter name").value
            param_type = self._parse_type()
            params.append(FunctionParam(name=name, type=param_type))

            self._skip_whitespace()  # Allow whitespace before comma
            if not self._match(TokenType.COMMA):
                break
            self._skip_whitespace()  # Allow whitespace after comma

        return params

    def _parse_function_body_statements(self) -> List[FunctionStatement]:
        """Parse function body into a list of statements.

        Statement types:
        - Assignment: IDENTIFIER '=' expression
        - Return: 'RETURN' expression
        - For loop: 'FOR' IDENTIFIER 'IN' expression ':' statements

        Statement boundaries are detected by recognizing starting patterns,
        not by newlines or semicolons.
        """
        statements = []

        while not self._at_end() and not self._check(TokenType.RPAREN):
            self._skip_whitespace()

            if self._check(TokenType.RPAREN):
                break

            stmt = self._parse_function_statement()
            if stmt:
                statements.append(stmt)

        return statements

    def _parse_function_statement(self, stop_at_else: bool = False) -> Optional[FunctionStatement]:
        """Parse a single function body statement.

        Args:
            stop_at_else: If True, stop parsing when ELSE is encountered (used in IF then-body)
        """
        self._skip_whitespace()

        token = self._peek()

        # Check for ELSE if we should stop there
        if stop_at_else and token.type == TokenType.ELSE:
            return None

        # RETURN statement
        if token.type == TokenType.RETURN:
            return self._parse_return_statement()

        # IF statement (as control flow, not expression)
        if token.type == TokenType.IDENTIFIER and token.value.upper() == 'IF':
            return self._parse_if_statement()

        # FOR loop
        if token.type == TokenType.IDENTIFIER and token.value.upper() == 'FOR':
            return self._parse_for_statement()

        # Assignment: IDENTIFIER = expression
        if token.type == TokenType.IDENTIFIER:
            # Look ahead to see if this is an assignment
            next_tok = self._peek_at(1)
            if next_tok and next_tok.type == TokenType.EQUALS:
                return self._parse_assignment_statement()

        # Skip unknown tokens (comments, newlines, etc.)
        if token.type in (TokenType.NEWLINE, TokenType.COMMENT):
            self._advance()
            return None

        # Unexpected token - skip it
        self._advance()
        return None

    def _parse_return_statement(self) -> ReturnStmt:
        """Parse: RETURN expression"""
        token = self._expect(TokenType.RETURN)
        expr = self._parse_expr()
        return ReturnStmt(expression=expr, line=token.line, column=token.column)

    def _parse_assignment_statement(self) -> AssignmentStmt:
        """Parse: IDENTIFIER = expression"""
        name_token = self._expect(TokenType.IDENTIFIER)
        self._expect(TokenType.EQUALS)
        expr = self._parse_expr()
        return AssignmentStmt(name=name_token.value, expression=expr,
                              line=name_token.line, column=name_token.column)

    def _parse_if_statement(self) -> IfStmt:
        """Parse: IF condition THEN statements ELSE statements"""
        token = self._advance()  # consume IF

        # Parse condition using expression parser
        condition = self._parse_expr()

        # Expect THEN
        then_token = self._peek()
        if then_token.type != TokenType.IDENTIFIER or then_token.value.upper() != 'THEN':
            raise ParseError(f"Expected 'THEN', got '{then_token.value}'", then_token)
        self._advance()

        # Parse then-body statements until ELSE or end
        then_body = []
        while not self._at_end() and not self._check(TokenType.RPAREN):
            self._skip_whitespace()
            if self._check(TokenType.RPAREN):
                break
            # Check for ELSE
            peek = self._peek()
            if peek.type == TokenType.ELSE:
                break
            stmt = self._parse_function_statement(stop_at_else=True)
            if stmt:
                then_body.append(stmt)
            else:
                break  # Couldn't parse a statement, might be at ELSE

        # Parse else-body if present
        else_body = []
        peek = self._peek()
        if peek.type == TokenType.ELSE:
            self._advance()  # consume ELSE
            while not self._at_end() and not self._check(TokenType.RPAREN):
                self._skip_whitespace()
                if self._check(TokenType.RPAREN):
                    break
                stmt = self._parse_function_statement()
                if stmt:
                    else_body.append(stmt)

        return IfStmt(condition=condition, then_body=then_body, else_body=else_body,
                      line=token.line, column=token.column)
    def _parse_for_statement(self) -> ForStmt:
        """Parse: FOR IDENTIFIER IN expression : statements"""
        token = self._advance()  # consume FOR
        var_token = self._expect(TokenType.IDENTIFIER, "Expected loop variable")

        # Expect 'IN' keyword
        self._expect(TokenType.IN, "Expected 'IN'")

        # Parse iterable expression - it naturally stops at colon since colon isn't a valid expression continuation
        iterable = self._parse_expr()
        self._expect(TokenType.COLON, "Expected ':' after FOR iterable")

        # Parse body statements - FOR loop body is a single statement
        # The statement is parsed and the body ends
        body = []
        self._skip_whitespace()
        if not self._at_end() and not self._check(TokenType.RPAREN) and not self._check(TokenType.RETURN):
            stmt = self._parse_function_statement()
            if stmt:
                body.append(stmt)

        return ForStmt(var_name=var_token.value, iterable=iterable, body=body,
                       line=token.line, column=token.column)

    def _is_function_call_context(self) -> bool:
        """Check if current LPAREN starts a function call (not an action block).

        Returns False if after ( there's a newline followed by an action keyword,
        which indicates this is an action block, not a function call.
        """
        # We're at LPAREN, peek ahead
        i = 1
        token = self._peek(i)

        # Skip whitespace/newlines to find first content after (
        while token.type in (TokenType.NEWLINE, TokenType.COMMENT):
            i += 1
            token = self._peek(i)
            if token.type == TokenType.EOF:
                return False

        # If after ( we see an action keyword, this is an action block, not a function call
        action_keywords = {
            TokenType.STORE, TokenType.COMPUTE, TokenType.LOOKUP,
            TokenType.SEND, TokenType.BROADCAST, TokenType.APPEND, TokenType.APPEND_BLOCK
        }
        if token.type in action_keywords:
            return False

        return True

    def _peek_at(self, offset: int) -> Optional[Token]:
        """Peek at a token at a given offset from current position."""
        pos = self.pos + offset
        # Skip newlines when peeking
        while pos < len(self.tokens) and self.tokens[pos].type == TokenType.NEWLINE:
            pos += 1
            offset += 1
        if pos < len(self.tokens):
            return self.tokens[pos]
        return None

    # =========================================================================
    # Expression parsing (recursive descent with proper precedence)
    # =========================================================================

    # Tokens that indicate we've left the expression context
    EXPR_STOP_TOKENS = {
        TokenType.NEWLINE, TokenType.COMMENT, TokenType.EOF,
        TokenType.STORE, TokenType.COMPUTE, TokenType.LOOKUP,
        TokenType.SEND, TokenType.BROADCAST, TokenType.APPEND, TokenType.APPEND_BLOCK
    }

    def _parse_expr(self) -> Expr:
        """Parse an expression - entry point."""
        return self._parse_or_expr()

    def _parse_or_expr(self) -> Expr:
        """Parse OR expression (lowest precedence)."""
        left = self._parse_and_expr()
        self._skip_expr_newlines()  # Allow multiline before 'or' when in grouping
        while self._check(TokenType.OR):
            token = self._advance()
            self._skip_expr_newlines()  # Allow multiline after 'or'
            right = self._parse_and_expr()
            self._skip_expr_newlines()  # Allow multiline before next 'or'
            left = BinaryExpr(left, BinaryOperator.OR, right, token.line, token.column)
        return left

    def _parse_and_expr(self) -> Expr:
        """Parse AND expression."""
        left = self._parse_not_expr()
        self._skip_expr_newlines()  # Allow multiline before 'and' when in grouping
        while self._check(TokenType.AND):
            token = self._advance()
            self._skip_expr_newlines()  # Allow multiline after 'and'
            right = self._parse_not_expr()
            self._skip_expr_newlines()  # Allow multiline before next 'and'
            left = BinaryExpr(left, BinaryOperator.AND, right, token.line, token.column)
        return left

    def _parse_not_expr(self) -> Expr:
        """Parse NOT expression (unary)."""
        if self._check(TokenType.NOT):
            token = self._advance()
            self._skip_expr_newlines()  # Allow multiline after 'not'
            operand = self._parse_not_expr()
            return UnaryExpr(UnaryOperator.NOT, operand, token.line, token.column)
        return self._parse_comparison_expr()

    def _parse_comparison_expr(self) -> Expr:
        """Parse comparison expressions (==, !=, <, >, <=, >=)."""
        left = self._parse_additive_expr()

        comparison_ops = {
            TokenType.EQ: BinaryOperator.EQ,
            TokenType.NEQ: BinaryOperator.NEQ,
            TokenType.LANGLE: BinaryOperator.LT,
            TokenType.RANGLE: BinaryOperator.GT,
            TokenType.LTE: BinaryOperator.LTE,
            TokenType.GTE: BinaryOperator.GTE,
        }

        self._skip_expr_newlines()  # Allow multiline before comparison when in grouping
        while self._peek().type in comparison_ops:
            token = self._advance()
            self._skip_expr_newlines()  # Allow multiline after comparison operator
            op = comparison_ops[token.type]
            right = self._parse_additive_expr()
            self._skip_expr_newlines()  # Allow multiline before next comparison
            left = BinaryExpr(left, op, right, token.line, token.column)

        return left

    def _parse_additive_expr(self) -> Expr:
        """Parse additive expressions (+, -)."""
        left = self._parse_multiplicative_expr()

        self._skip_expr_newlines()  # Allow multiline before +/- when in grouping
        while self._check(TokenType.PLUS) or self._check(TokenType.MINUS):
            token = self._advance()
            self._skip_expr_newlines()  # Allow multiline after +/-
            op = BinaryOperator.ADD if token.type == TokenType.PLUS else BinaryOperator.SUB
            right = self._parse_multiplicative_expr()
            self._skip_expr_newlines()  # Allow multiline before next +/-
            left = BinaryExpr(left, op, right, token.line, token.column)

        return left

    def _parse_multiplicative_expr(self) -> Expr:
        """Parse multiplicative expressions (*, /)."""
        left = self._parse_unary_expr()

        self._skip_expr_newlines()  # Allow multiline before * or / when in grouping
        while self._check(TokenType.STAR) or self._check(TokenType.SLASH):
            token = self._advance()
            self._skip_expr_newlines()  # Allow multiline after * or /
            op = BinaryOperator.MUL if token.type == TokenType.STAR else BinaryOperator.DIV
            right = self._parse_unary_expr()
            self._skip_expr_newlines()  # Allow multiline before next * or /
            left = BinaryExpr(left, op, right, token.line, token.column)

        return left

    def _parse_unary_expr(self) -> Expr:
        """Parse unary minus."""
        if self._check(TokenType.MINUS):
            token = self._advance()
            operand = self._parse_unary_expr()
            return UnaryExpr(UnaryOperator.NEG, operand, token.line, token.column)
        return self._parse_postfix_expr()

    def _parse_postfix_expr(self) -> Expr:
        """Parse postfix expressions (function calls, field access, index access)."""
        expr = self._parse_primary_expr()

        while True:
            if self._check(TokenType.LPAREN):
                # Function call - but only if expr is an identifier
                # Also check that what follows ( looks like function arguments, not an action block
                # Action blocks start with newline followed by action keywords
                if isinstance(expr, Identifier) and self._is_function_call_context():
                    expr = self._parse_function_call(expr.name, expr.line, expr.column)
                else:
                    break
            elif self._check(TokenType.DOT):
                self._advance()
                if self._check(TokenType.LBRACE):
                    # Dynamic field access: obj.{key}
                    self._advance()
                    key_expr = self._parse_expr()
                    self._expect(TokenType.RBRACE, "Expected '}' after dynamic field key")
                    expr = DynamicFieldAccessExpr(expr, key_expr, expr.line, expr.column)
                else:
                    # Static field access: obj.field
                    field_token = self._expect(TokenType.IDENTIFIER, "Expected field name after '.'")
                    expr = FieldAccessExpr(expr, field_token.value, expr.line, expr.column)
            elif self._check(TokenType.LBRACKET):
                # Index access: obj[index]
                self._advance()
                index = self._parse_expr()
                self._expect(TokenType.RBRACKET, "Expected ']' after index")
                expr = IndexAccessExpr(expr, index, expr.line, expr.column)
            else:
                break

        # Check for lambda: identifier => body
        if isinstance(expr, Identifier) and self._check(TokenType.FATARROW):
            self._advance()
            self._skip_whitespace()  # Allow multiline after =>
            body = self._parse_expr()
            return LambdaExpr(expr.name, body, expr.line, expr.column)

        return expr

    def _parse_function_call(self, name: str, line: int, column: int) -> FunctionCallExpr:
        """Parse function call arguments."""
        self._expect(TokenType.LPAREN, "Expected '(' for function call")
        self._grouping_depth += 1
        try:
            self._skip_whitespace()  # Allow multiline after (
            args = []

            if not self._check(TokenType.RPAREN):
                args.append(self._parse_expr())
                self._skip_whitespace()  # Allow multiline after argument
                while self._match(TokenType.COMMA):
                    self._skip_whitespace()  # Allow multiline after comma
                    args.append(self._parse_expr())
                    self._skip_whitespace()  # Allow multiline after argument

            self._expect(TokenType.RPAREN, "Expected ')' after function arguments")
            return FunctionCallExpr(name, args, line, column)
        finally:
            self._grouping_depth -= 1

    def _parse_primary_expr(self) -> Expr:
        """Parse primary expressions (literals, identifiers, grouped, if, struct, list)."""
        token = self._peek()

        # IF expression
        if token.value.upper() == 'IF' and token.type == TokenType.IDENTIFIER:
            return self._parse_if_expr()

        # Struct literal: { ... }
        if self._check(TokenType.LBRACE):
            return self._parse_struct_literal()

        # List literal: [ ... ]
        if self._check(TokenType.LBRACKET):
            return self._parse_list_literal()

        # Grouped expression or paren-based struct literal: ( ... )
        if self._check(TokenType.LPAREN):
            paren_token = self._advance()
            self._grouping_depth += 1
            try:
                self._skip_whitespace()  # Allow multiline expressions inside parens

                # Check if this is a paren-based struct literal: (field = value, ...)
                # by looking for identifier followed by = (but not ==)
                if (self._check(TokenType.IDENTIFIER) and
                    self._peek(1).type == TokenType.EQUALS and
                    self._peek(2).type != TokenType.EQUALS):
                    # Parse as struct literal using parens
                    return self._parse_paren_struct_literal(paren_token)

                # Regular grouped expression
                expr = self._parse_expr()
                self._skip_whitespace()  # Allow trailing newlines before )
                self._expect(TokenType.RPAREN, "Expected ')' after grouped expression")
                return expr
            finally:
                self._grouping_depth -= 1

        # String literal
        if self._check(TokenType.STRING):
            token = self._advance()
            return Literal(token.value, "string", token.line, token.column)

        # Number literal
        if self._check(TokenType.NUMBER):
            token = self._advance()
            value = float(token.value) if '.' in token.value else int(token.value)
            return Literal(value, "number", token.line, token.column)

        # Boolean literals (true, false) and null
        if self._check(TokenType.IDENTIFIER):
            if token.value.lower() == 'true':
                self._advance()
                return Literal(True, "bool", token.line, token.column)
            elif token.value.lower() == 'false':
                self._advance()
                return Literal(False, "bool", token.line, token.column)
            elif token.value.lower() == 'null':
                self._advance()
                return Literal(None, "null", token.line, token.column)

        # Identifier (variable or enum reference)
        if self._check(TokenType.IDENTIFIER):
            token = self._advance()
            name = token.value

            # Check for enum reference: EnumName.VALUE
            if self._check(TokenType.DOT):
                # Peek ahead to see if it's an identifier (enum value) vs brace (dynamic access)
                if self._peek(1).type == TokenType.IDENTIFIER:
                    self._advance()  # consume .
                    value_token = self._advance()
                    return EnumRefExpr(name, value_token.value, token.line, token.column)

            return Identifier(name, token.line, token.column)

        # MESSAGE keyword can be used as an identifier (e.g., message.sender, message.payload)
        if self._check(TokenType.MESSAGE):
            token = self._advance()
            return Identifier(token.value, token.line, token.column)

        raise ParseError(f"Unexpected token in expression: {token.value}", token)

    def _parse_if_expr(self) -> IfExpr:
        """Parse IF condition THEN expr ELSE expr."""
        token = self._advance()  # consume 'IF'
        self._skip_whitespace()  # Allow multiline after IF
        condition = self._parse_expr()

        # Expect THEN - can be either IDENTIFIER 'THEN' or a dedicated token
        self._skip_whitespace()  # Allow multiline before THEN
        then_token = self._peek()
        is_then = (then_token.type == TokenType.IDENTIFIER and then_token.value.upper() == 'THEN')
        if not is_then:
            raise ParseError("Expected 'THEN' after IF condition", then_token)
        self._advance()

        self._skip_whitespace()  # Allow multiline after THEN
        then_expr = self._parse_expr()

        # Expect ELSE - can be either TokenType.ELSE or IDENTIFIER 'ELSE'
        self._skip_whitespace()  # Allow multiline before ELSE
        else_token = self._peek()
        is_else = (else_token.type == TokenType.ELSE or
                   (else_token.type == TokenType.IDENTIFIER and else_token.value.upper() == 'ELSE'))
        if not is_else:
            raise ParseError("Expected 'ELSE' after THEN expression", else_token)
        self._advance()

        self._skip_whitespace()  # Allow multiline after ELSE
        else_expr = self._parse_expr()

        return IfExpr(condition, then_expr, else_expr, token.line, token.column)

    def _parse_struct_literal(self) -> StructLiteralExpr:
        """Parse struct literal: { field: value, ... } or { ...spread, field: value }."""
        token = self._expect(TokenType.LBRACE, "Expected '{'")
        self._grouping_depth += 1
        try:
            fields = {}
            spread = None

            self._skip_whitespace()
            while not self._check(TokenType.RBRACE) and not self._at_end():
                # Check for spread: ...expr
                if self._check(TokenType.DOT):
                    # Check for ... (three dots)
                    if self._peek(1).type == TokenType.DOT and self._peek(2).type == TokenType.DOT:
                        self._advance()  # first .
                        self._advance()  # second .
                        self._advance()  # third .
                        spread = self._parse_expr()
                        if self._check(TokenType.COMMA):
                            self._advance()
                        self._skip_whitespace()
                        continue

                # Regular field: name: value OR shorthand: name (equivalent to name: name)
                field_token = self._expect(TokenType.IDENTIFIER, "Expected field name")
                if self._check(TokenType.COLON):
                    self._advance()  # consume :
                    self._skip_whitespace()  # Allow multiline after :
                    value = self._parse_expr()
                else:
                    # Shorthand syntax: just identifier means identifier: identifier
                    value = Identifier(field_token.value, field_token.line, field_token.column)
                fields[field_token.value] = value

                if self._check(TokenType.COMMA):
                    self._advance()
                self._skip_whitespace()

            self._expect(TokenType.RBRACE, "Expected '}' to close struct literal")
            return StructLiteralExpr(fields, spread, token.line, token.column)
        finally:
            self._grouping_depth -= 1

    def _parse_paren_struct_literal(self, token: Token) -> StructLiteralExpr:
        """Parse paren-based struct literal: (field = value, ...).

        This is an alternative struct literal syntax using parens instead of braces,
        commonly used in compute expressions. Note: already consumed opening '('.
        """
        fields = {}

        while not self._check(TokenType.RPAREN) and not self._at_end():
            # Expect field name
            field_token = self._expect(TokenType.IDENTIFIER, "Expected field name")
            self._expect(TokenType.EQUALS, "Expected '=' after field name")
            self._skip_whitespace()  # Allow multiline after =
            value = self._parse_expr()
            fields[field_token.value] = value

            # Optional comma between fields
            if self._check(TokenType.COMMA):
                self._advance()
            self._skip_whitespace()

        self._expect(TokenType.RPAREN, "Expected ')' to close struct literal")
        return StructLiteralExpr(fields, None, token.line, token.column)

    def _parse_list_literal(self) -> ListLiteralExpr:
        """Parse list literal: [a, b, c]."""
        token = self._expect(TokenType.LBRACKET, "Expected '['")
        self._grouping_depth += 1
        try:
            elements = []

            self._skip_whitespace()
            if not self._check(TokenType.RBRACKET):
                elements.append(self._parse_expr())
                self._skip_whitespace()  # Allow multiline after element
                while self._match(TokenType.COMMA):
                    self._skip_whitespace()
                    if self._check(TokenType.RBRACKET):
                        break  # Allow trailing comma
                    elements.append(self._parse_expr())
                    self._skip_whitespace()  # Allow multiline after element

            self._expect(TokenType.RBRACKET, "Expected ']' to close list literal")
            return ListLiteralExpr(elements, token.line, token.column)
        finally:
            self._grouping_depth -= 1

    def _parse_guard_expression(self) -> Expr:
        """Parse a guard expression - returns an Expr AST node."""
        return self._parse_expr()

    def _parse_expression(self) -> Expr:
        """Parse an expression - returns an Expr AST node."""
        return self._parse_expr()

    # =========================================================================
    # Type parsing
    # =========================================================================

    def _parse_type(self) -> TypeExpr:
        """Parse a type: NAME or list<TYPE> or map<KEY, VALUE>"""
        token = self._expect(TokenType.IDENTIFIER, "Expected type name")
        name = token.value

        if self._match(TokenType.LANGLE):
            self._skip_whitespace()  # Allow whitespace after <
            # Generic type: list<T> or map<K, V>
            if name.lower() == 'list':
                element_type = self._parse_type()
                self._skip_whitespace()  # Allow whitespace before >
                self._expect(TokenType.RANGLE, "Expected '>' to close list type")
                return ListType(element_type, token.line, token.column)
            elif name.lower() == 'map':
                key_type = self._parse_type()
                self._skip_whitespace()  # Allow whitespace before comma
                self._expect(TokenType.COMMA, "Expected ',' in map type")
                self._skip_whitespace()  # Allow whitespace after comma
                value_type = self._parse_type()
                self._skip_whitespace()  # Allow whitespace before >
                self._expect(TokenType.RANGLE, "Expected '>' to close map type")
                return MapType(key_type, value_type, token.line, token.column)
            else:
                # Unknown generic - treat as simple type with generic suffix for now
                type_params = [self._parse_type()]
                self._skip_whitespace()  # Allow whitespace before comma or >
                while self._match(TokenType.COMMA):
                    self._skip_whitespace()  # Allow whitespace after comma
                    type_params.append(self._parse_type())
                    self._skip_whitespace()  # Allow whitespace before next comma or >
                self._expect(TokenType.RANGLE, "Expected '>' to close generic type")
                # Fallback: create simple type with generic syntax preserved
                param_strs = [_type_to_str(tp) for tp in type_params]
                return SimpleType(f"{name}<{', '.join(param_strs)}>", token.line, token.column)

        return SimpleType(name, token.line, token.column)

    # =========================================================================
    # Utility parsing
    # =========================================================================

    def _parse_identifier_list(self) -> List[str]:
        """Parse comma-separated identifiers."""
        self._skip_whitespace()  # Allow leading whitespace
        ids = [self._expect(TokenType.IDENTIFIER, "Expected identifier").value]

        self._skip_whitespace()  # Allow whitespace before comma
        while self._match(TokenType.COMMA):
            self._skip_whitespace()  # Allow whitespace after comma
            ids.append(self._expect(TokenType.IDENTIFIER, "Expected identifier").value)
            self._skip_whitespace()  # Allow whitespace before next comma

        return ids

    def _parse_fields(self) -> List[Field]:
        """Parse field declarations: NAME TYPE (one per line)."""
        fields = []
        self._skip_whitespace()

        while not self._check(TokenType.RPAREN) and not self._at_end():
            if self._check(TokenType.COMMENT):
                self._advance()
                self._skip_whitespace()
                continue

            token = self._expect(TokenType.IDENTIFIER, "Expected field name")
            name = token.value
            field_type = self._parse_type()

            fields.append(Field(name=name, type=field_type,
                               line=token.line, column=token.column))
            self._skip_whitespace()

        return fields


def parse(source: str) -> Schema:
    """Convenience function to parse source code into a Schema."""
    tokens = tokenize(source)
    parser = Parser(tokens)
    return parser.parse()
