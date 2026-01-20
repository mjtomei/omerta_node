"""
Lexer for the transaction DSL.

Tokenizes the input into a stream of tokens for the parser.
"""

import re
from dataclasses import dataclass
from enum import Enum, auto
from typing import List, Optional, Iterator


class TokenType(Enum):
    # Keywords
    TRANSACTION = auto()
    IMPORTS = auto()
    PARAMETERS = auto()
    ENUM = auto()
    MESSAGE = auto()
    BLOCK = auto()
    ACTOR = auto()
    FUNCTION = auto()
    NATIVE = auto()
    STORE = auto()
    TRIGGER = auto()
    STATE = auto()
    LOOKUP = auto()
    SEND = auto()
    BROADCAST = auto()
    APPEND = auto()
    APPEND_BLOCK = auto()
    ELSE = auto()

    # Modifiers
    FROM = auto()
    TO = auto()
    BY = auto()
    IN = auto()
    ON = auto()
    AUTO = auto()
    WHEN = auto()
    WITH = auto()
    SIGNED = auto()
    INITIAL = auto()
    TERMINAL = auto()
    RETURN = auto()

    # Logical operators
    AND = auto()
    OR = auto()
    NOT = auto()

    # Symbols
    LPAREN = auto()      # (
    RPAREN = auto()      # )
    LBRACKET = auto()    # [
    RBRACKET = auto()    # ]
    LBRACE = auto()      # {
    RBRACE = auto()      # }
    LANGLE = auto()      # <
    RANGLE = auto()      # >
    ARROW = auto()       # ->
    LARROW = auto()      # <-
    FATARROW = auto()    # =>
    EQUALS = auto()      # =
    COMMA = auto()       # ,
    DOT = auto()         # .
    COLON = auto()       # :

    # Comparison operators
    EQ = auto()          # ==
    NEQ = auto()         # !=
    LTE = auto()         # <=
    GTE = auto()         # >=

    # Arithmetic operators
    PLUS = auto()        # +
    MINUS = auto()       # -
    STAR = auto()        # *
    SLASH = auto()       # /

    # Literals
    STRING = auto()
    NUMBER = auto()
    IDENTIFIER = auto()

    # Special
    NEWLINE = auto()
    COMMENT = auto()
    EOF = auto()


@dataclass
class Token:
    type: TokenType
    value: str
    line: int
    column: int

    def __repr__(self):
        return f"Token({self.type.name}, {self.value!r}, {self.line}:{self.column})"


# Keywords mapping
KEYWORDS = {
    'transaction': TokenType.TRANSACTION,
    'imports': TokenType.IMPORTS,
    'parameters': TokenType.PARAMETERS,
    'enum': TokenType.ENUM,
    'message': TokenType.MESSAGE,
    'block': TokenType.BLOCK,
    'actor': TokenType.ACTOR,
    'function': TokenType.FUNCTION,
    'native': TokenType.NATIVE,
    'store': TokenType.STORE,
    'trigger': TokenType.TRIGGER,
    'state': TokenType.STATE,
    'lookup': TokenType.LOOKUP,
    'send': TokenType.SEND,
    'broadcast': TokenType.BROADCAST,
    'append': TokenType.APPEND,
    'append_block': TokenType.APPEND_BLOCK,
    'else': TokenType.ELSE,
    'from': TokenType.FROM,
    'to': TokenType.TO,
    'by': TokenType.BY,
    'in': TokenType.IN,
    'on': TokenType.ON,
    'auto': TokenType.AUTO,
    'when': TokenType.WHEN,
    'with': TokenType.WITH,
    'signed': TokenType.SIGNED,
    'initial': TokenType.INITIAL,
    'terminal': TokenType.TERMINAL,
    'return': TokenType.RETURN,
    'and': TokenType.AND,
    'or': TokenType.OR,
    'not': TokenType.NOT,
}


class LexerError(Exception):
    """Raised when lexer encounters invalid input."""
    def __init__(self, message: str, line: int, column: int):
        self.line = line
        self.column = column
        super().__init__(f"Line {line}, column {column}: {message}")


class Lexer:
    """Tokenizer for the transaction DSL."""

    def __init__(self, source: str):
        self.source = source
        self.pos = 0
        self.line = 1
        self.column = 1
        self.tokens: List[Token] = []

    def tokenize(self) -> List[Token]:
        """Tokenize the entire source and return list of tokens."""
        while not self._at_end():
            self._scan_token()

        self.tokens.append(Token(TokenType.EOF, '', self.line, self.column))
        return self.tokens

    def _at_end(self) -> bool:
        return self.pos >= len(self.source)

    def _peek(self, offset: int = 0) -> str:
        pos = self.pos + offset
        if pos >= len(self.source):
            return '\0'
        return self.source[pos]

    def _advance(self) -> str:
        char = self.source[self.pos]
        self.pos += 1
        if char == '\n':
            self.line += 1
            self.column = 1
        else:
            self.column += 1
        return char

    def _match(self, expected: str) -> bool:
        if self._at_end() or self.source[self.pos] != expected:
            return False
        self._advance()
        return True

    def _add_token(self, token_type: TokenType, value: str, line: int, column: int):
        self.tokens.append(Token(token_type, value, line, column))

    def _skip_whitespace(self):
        while not self._at_end() and self._peek() in ' \t\r':
            self._advance()

    def _scan_token(self):
        self._skip_whitespace()

        if self._at_end():
            return

        start_line = self.line
        start_column = self.column
        char = self._advance()

        # Newlines
        if char == '\n':
            self._add_token(TokenType.NEWLINE, '\n', start_line, start_column)
            return

        # Comments
        if char == '#':
            comment = '#'
            while not self._at_end() and self._peek() != '\n':
                comment += self._advance()
            self._add_token(TokenType.COMMENT, comment, start_line, start_column)
            return

        # Strings
        if char == '"':
            self._scan_string(start_line, start_column)
            return

        # Numbers
        if char.isdigit() or (char == '-' and self._peek().isdigit()):
            self._scan_number(char, start_line, start_column)
            return

        # Identifiers and keywords
        if char.isalpha() or char == '_':
            self._scan_identifier(char, start_line, start_column)
            return

        # Two-character tokens
        if char == '-' and self._match('>'):
            self._add_token(TokenType.ARROW, '->', start_line, start_column)
            return
        if char == '<' and self._match('-'):
            self._add_token(TokenType.LARROW, '<-', start_line, start_column)
            return
        if char == '=' and self._match('='):
            self._add_token(TokenType.EQ, '==', start_line, start_column)
            return
        if char == '!' and self._match('='):
            self._add_token(TokenType.NEQ, '!=', start_line, start_column)
            return
        if char == '<' and self._match('='):
            self._add_token(TokenType.LTE, '<=', start_line, start_column)
            return
        if char == '>' and self._match('='):
            self._add_token(TokenType.GTE, '>=', start_line, start_column)
            return
        if char == '=' and self._match('>'):
            # Lambda arrow =>
            self._add_token(TokenType.FATARROW, '=>', start_line, start_column)
            return

        # Single-character tokens
        single_char_tokens = {
            '(': TokenType.LPAREN,
            ')': TokenType.RPAREN,
            '[': TokenType.LBRACKET,
            ']': TokenType.RBRACKET,
            '{': TokenType.LBRACE,
            '}': TokenType.RBRACE,
            '<': TokenType.LANGLE,
            '>': TokenType.RANGLE,
            '=': TokenType.EQUALS,
            ',': TokenType.COMMA,
            '.': TokenType.DOT,
            ':': TokenType.COLON,
            '+': TokenType.PLUS,
            '-': TokenType.MINUS,
            '*': TokenType.STAR,
            '/': TokenType.SLASH,
        }

        if char in single_char_tokens:
            self._add_token(single_char_tokens[char], char, start_line, start_column)
            return

        raise LexerError(f"Unexpected character: {char!r}", start_line, start_column)

    def _scan_string(self, start_line: int, start_column: int):
        value = ''
        while not self._at_end() and self._peek() != '"':
            if self._peek() == '\n':
                raise LexerError("Unterminated string", start_line, start_column)
            if self._peek() == '\\':
                self._advance()
                if self._at_end():
                    raise LexerError("Unterminated string escape", start_line, start_column)
                escape_char = self._advance()
                escape_map = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}
                value += escape_map.get(escape_char, escape_char)
            else:
                value += self._advance()

        if self._at_end():
            raise LexerError("Unterminated string", start_line, start_column)

        self._advance()  # Closing "
        self._add_token(TokenType.STRING, value, start_line, start_column)

    def _scan_number(self, first_char: str, start_line: int, start_column: int):
        value = first_char
        while not self._at_end() and (self._peek().isdigit() or self._peek() == '.'):
            if self._peek() == '.' and '.' in value:
                break  # Already have a decimal point
            value += self._advance()

        self._add_token(TokenType.NUMBER, value, start_line, start_column)

    def _scan_identifier(self, first_char: str, start_line: int, start_column: int):
        value = first_char
        while not self._at_end() and (self._peek().isalnum() or self._peek() == '_'):
            value += self._advance()

        # Check for keywords
        token_type = KEYWORDS.get(value.lower(), TokenType.IDENTIFIER)

        # Keep original case for identifiers
        self._add_token(token_type, value, start_line, start_column)


def tokenize(source: str) -> List[Token]:
    """Convenience function to tokenize source code."""
    lexer = Lexer(source)
    return lexer.tokenize()
