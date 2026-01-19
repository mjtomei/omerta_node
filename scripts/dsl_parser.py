"""
Parser for the transaction DSL.

Parses a token stream into an AST.
"""

from typing import List, Optional, Set

try:
    from .dsl_lexer import Token, TokenType, tokenize, LexerError
    from .dsl_ast import (
        Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
        Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, StateDecl,
        Transition, StoreAction, ComputeAction, SendAction, AppendAction,
        AppendBlockAction, FunctionDecl, FunctionParam, Action
    )
except ImportError:
    from dsl_lexer import Token, TokenType, tokenize, LexerError
    from dsl_ast import (
    Schema, Transaction, Import, Parameter, EnumDecl, EnumValue,
    Field, MessageDecl, BlockDecl, ActorDecl, TriggerDecl, StateDecl,
    Transition, StoreAction, ComputeAction, SendAction, AppendAction,
    AppendBlockAction, FunctionDecl, FunctionParam, Action
)


class ParseError(Exception):
    """Raised when parser encounters invalid syntax."""
    def __init__(self, message: str, token: Token):
        self.token = token
        super().__init__(f"Line {token.line}, column {token.column}: {message}")


class Parser:
    """Recursive descent parser for the transaction DSL."""

    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0

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
        """Parse: transaction ID STRING"""
        token = self._expect(TokenType.TRANSACTION)
        # ID can be either identifier or number
        if self._check(TokenType.NUMBER):
            tx_id = self._advance().value
        elif self._check(TokenType.IDENTIFIER):
            tx_id = self._advance().value
        else:
            raise ParseError("Expected transaction ID", self._peek())
        name = self._expect(TokenType.STRING, "Expected transaction name").value
        return Transaction(id=tx_id, name=name, line=token.line, column=token.column)

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
        """Parse: enum NAME ( VALUE VALUE ... )"""
        token = self._expect(TokenType.ENUM)
        name = self._expect(TokenType.IDENTIFIER, "Expected enum name").value
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
        return EnumDecl(name=name, values=values, line=token.line, column=token.column)

    def _parse_message(self) -> MessageDecl:
        """Parse: message NAME from SENDER to [RECIPIENTS] signed? ( fields )"""
        token = self._expect(TokenType.MESSAGE)
        name = self._expect(TokenType.IDENTIFIER, "Expected message name").value

        self._expect(TokenType.FROM, "Expected 'from'")
        sender = self._expect(TokenType.IDENTIFIER, "Expected sender").value

        self._expect(TokenType.TO, "Expected 'to'")
        self._expect(TokenType.LBRACKET, "Expected '[' before recipients")
        recipients = self._parse_identifier_list()
        self._expect(TokenType.RBRACKET, "Expected ']' after recipients")

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
        name = self._expect(TokenType.IDENTIFIER, "Expected block name").value

        self._expect(TokenType.BY, "Expected 'by'")
        self._expect(TokenType.LBRACKET, "Expected '[' before actors")
        appended_by = self._parse_identifier_list()
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
        """Parse: trigger NAME(params) in [STATES] "description"?"""
        token = self._expect(TokenType.TRIGGER)
        name = self._expect(TokenType.IDENTIFIER, "Expected trigger name").value

        # Parse parameters
        self._expect(TokenType.LPAREN, "Expected '(' for trigger params")
        params = []
        if not self._check(TokenType.RPAREN):
            params = self._parse_identifier_list()
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
        """Parse: FROM -> TO (on TRIGGER | auto) (when GUARD)? ( actions )?"""
        token = self._peek()
        from_state = self._expect(TokenType.IDENTIFIER, "Expected source state").value
        self._expect(TokenType.ARROW, "Expected '->'")
        to_state = self._expect(TokenType.IDENTIFIER, "Expected target state").value

        # Trigger or auto
        trigger = None
        auto = False
        if self._match(TokenType.ON):
            # Could be a message name, trigger name, or timeout(...)
            trigger = self._parse_trigger_spec()
        elif self._match(TokenType.AUTO):
            auto = True
        else:
            raise ParseError("Expected 'on' or 'auto' after transition", self._peek())

        # Optional guard
        guard = None
        if self._match(TokenType.WHEN):
            guard = self._parse_expression()

        # Optional actions block
        actions = []
        self._skip_whitespace()
        if self._check(TokenType.LPAREN):
            self._advance()
            actions = self._parse_actions()
            self._expect(TokenType.RPAREN, "Expected ')' to close actions")

        return Transition(
            from_state=from_state, to_state=to_state, trigger=trigger,
            auto=auto, guard=guard, actions=actions,
            line=token.line, column=token.column
        )

    def _parse_trigger_spec(self) -> str:
        """Parse trigger specification: NAME or timeout(PARAM)"""
        name = self._expect(TokenType.IDENTIFIER, "Expected trigger name").value

        # Check for timeout(PARAM) syntax - only if name is 'timeout'
        if name == 'timeout' and self._check(TokenType.LPAREN):
            self._advance()
            param = self._expect(TokenType.IDENTIFIER, "Expected timeout parameter").value
            self._expect(TokenType.RPAREN, "Expected ')' after timeout parameter")
            return f"timeout({param})"

        return name

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
            elif self._check(TokenType.SEND):
                actions.append(self._parse_send_action())
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
        """Parse: store x, y, z  OR  store x = expr"""
        token = self._expect(TokenType.STORE)
        action = StoreAction(line=token.line, column=token.column)

        first_id = self._expect(TokenType.IDENTIFIER, "Expected field name").value

        if self._match(TokenType.EQUALS):
            # store x = expr
            expr = self._parse_expression()
            action.assignments[first_id] = expr
        elif self._match(TokenType.COMMA):
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

    def _parse_send_action(self) -> SendAction:
        """Parse: send MESSAGE to TARGET"""
        token = self._expect(TokenType.SEND)
        message = self._expect(TokenType.IDENTIFIER, "Expected message name").value
        self._expect(TokenType.TO, "Expected 'to'")
        target = self._parse_send_target()

        return SendAction(message=message, target=target,
                         line=token.line, column=token.column)

    def _parse_send_target(self) -> str:
        """Parse send target: identifier or each(list)"""
        name = self._expect(TokenType.IDENTIFIER, "Expected target").value

        if self._check(TokenType.LPAREN):
            # each(list) or similar
            self._advance()
            inner = self._expect(TokenType.IDENTIFIER, "Expected list name").value
            self._expect(TokenType.RPAREN, "Expected ')'")
            return f"{name}({inner})"

        return name

    def _parse_append_action(self) -> AppendAction:
        """Parse: append LIST <- VALUE"""
        token = self._expect(TokenType.APPEND)
        list_name = self._expect(TokenType.IDENTIFIER, "Expected list name").value
        self._expect(TokenType.LARROW, "Expected '<-'")
        value = self._parse_expression()

        return AppendAction(list_name=list_name, value=value,
                           line=token.line, column=token.column)

    def _parse_append_block_action(self) -> AppendBlockAction:
        """Parse: append_block BLOCK_TYPE"""
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

        # Body
        self._skip_whitespace()
        self._expect(TokenType.LPAREN, "Expected '(' for function body")
        body = self._parse_function_body()
        self._expect(TokenType.RPAREN, "Expected ')' to close function")

        return FunctionDecl(
            name=name, params=params, return_type=return_type, body=body,
            line=token.line, column=token.column
        )

    def _parse_function_params(self) -> List[FunctionParam]:
        """Parse function parameters: name type, name type, ..."""
        params = []

        while True:
            name = self._expect(TokenType.IDENTIFIER, "Expected parameter name").value
            param_type = self._parse_type()
            params.append(FunctionParam(name=name, type=param_type))

            if not self._match(TokenType.COMMA):
                break

        return params

    def _parse_function_body(self) -> str:
        """Parse function body - collect tokens until closing paren."""
        body_parts = []
        depth = 1  # We've already consumed the opening paren

        while depth > 0 and not self._at_end():
            token = self._peek()
            if token.type == TokenType.LPAREN:
                depth += 1
                body_parts.append('(')
                self._advance()
            elif token.type == TokenType.RPAREN:
                depth -= 1
                if depth > 0:
                    body_parts.append(')')
                    self._advance()
            elif token.type == TokenType.NEWLINE:
                body_parts.append('\n')
                self._advance()
            elif token.type == TokenType.COMMENT:
                body_parts.append(token.value)
                self._advance()
            elif token.type == TokenType.STRING:
                body_parts.append(f'"{token.value}"')
                self._advance()
            else:
                body_parts.append(token.value)
                self._advance()
                # Add space after most tokens
                if token.type not in (TokenType.LPAREN, TokenType.DOT):
                    next_tok = self._peek()
                    if next_tok.type not in (TokenType.RPAREN, TokenType.COMMA, TokenType.DOT,
                                             TokenType.NEWLINE, TokenType.EOF):
                        body_parts.append(' ')

        return ''.join(body_parts).strip()

    # =========================================================================
    # Expression parsing
    # =========================================================================

    def _parse_expression(self) -> str:
        """Parse an expression - collect tokens until we hit a delimiter."""
        # Delimiters that end an expression
        # Note: RPAREN and RBRACKET are handled separately by nesting logic
        delimiters = {
            TokenType.NEWLINE, TokenType.COMMENT,
            TokenType.STORE, TokenType.COMPUTE, TokenType.SEND,
            TokenType.APPEND, TokenType.APPEND_BLOCK
        }

        parts = []
        paren_depth = 0
        bracket_depth = 0

        while not self._at_end():
            token = self._peek()

            # Track nesting
            if token.type == TokenType.LPAREN:
                paren_depth += 1
            elif token.type == TokenType.RPAREN:
                if paren_depth == 0:
                    break
                paren_depth -= 1
            elif token.type == TokenType.LBRACKET:
                bracket_depth += 1
            elif token.type == TokenType.RBRACKET:
                if bracket_depth == 0:
                    break
                bracket_depth -= 1

            # Stop at delimiters (unless nested)
            if token.type in delimiters and paren_depth == 0 and bracket_depth == 0:
                break

            # Handle 'and' and 'or' keywords in expressions
            if token.type == TokenType.AND:
                parts.append(' and ')
                self._advance()
                continue
            if token.type == TokenType.OR:
                parts.append(' or ')
                self._advance()
                continue

            # Collect token
            if token.type == TokenType.STRING:
                parts.append(f'"{token.value}"')
            else:
                parts.append(token.value)
            self._advance()

            # Add spacing
            next_tok = self._peek()
            if token.type not in (TokenType.LPAREN, TokenType.DOT, TokenType.LBRACKET):
                if next_tok.type not in (TokenType.RPAREN, TokenType.COMMA, TokenType.DOT,
                                         TokenType.RBRACKET, TokenType.NEWLINE, TokenType.EOF,
                                         TokenType.LBRACKET, TokenType.LPAREN) and \
                   next_tok.type not in delimiters:
                    parts.append(' ')

        return ''.join(parts).strip()

    # =========================================================================
    # Type parsing
    # =========================================================================

    def _parse_type(self) -> str:
        """Parse a type: NAME or NAME<TYPE, TYPE>"""
        name = self._expect(TokenType.IDENTIFIER, "Expected type name").value

        if self._match(TokenType.LANGLE):
            # Generic type
            type_params = [self._parse_type()]
            while self._match(TokenType.COMMA):
                type_params.append(self._parse_type())
            self._expect(TokenType.RANGLE, "Expected '>' to close generic type")
            return f"{name}<{', '.join(type_params)}>"

        return name

    # =========================================================================
    # Utility parsing
    # =========================================================================

    def _parse_identifier_list(self) -> List[str]:
        """Parse comma-separated identifiers."""
        ids = [self._expect(TokenType.IDENTIFIER, "Expected identifier").value]

        while self._match(TokenType.COMMA):
            ids.append(self._expect(TokenType.IDENTIFIER, "Expected identifier").value)

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
