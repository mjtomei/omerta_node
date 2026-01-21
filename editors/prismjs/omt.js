/**
 * Omerta Transaction DSL (.omt) language definition for Prism.js
 *
 * Usage:
 *   <script src="prism-omt.js"></script>
 *
 * Or with bundler:
 *   import './prism-omt.js';
 */

Prism.languages.omt = {
  'comment': {
    pattern: /#.*/,
    greedy: true
  },
  'string': {
    pattern: /"(?:[^"\\]|\\.)*"/,
    greedy: true
  },
  'builtin': {
    pattern: /\b(?:HASH|SIGN|VERIFY_SIG|MULTI_SIGN|RANDOM_BYTES|GENERATE_ID|LENGTH|CONCAT|SORT|HAS_KEY|ABS|MIN|MAX|FILTER|MAP|GET|CONTAINS|REMOVE|SEND|BROADCAST|STORE|APPEND|LOAD|NOW|READ|CHAIN_CONTAINS_HASH|CHAIN_STATE_AT|CHAIN_SEGMENT|VERIFY_CHAIN_SEGMENT|SEEDED_RNG|SEEDED_SAMPLE|SET_EQUALS|EXTRACT_FIELD|COUNT_MATCHING|SELECT_WITNESSES|VERIFY_WITNESS_SELECTION|VALIDATE_LOCK_RESULT|VALIDATE_TOPUP_RESULT|IF|THEN|ELSE|AND|OR|NOT|RETURN)\b/,
    alias: 'function'
  },
  'constant': {
    pattern: /\b[A-Z][A-Z0-9_]+\b/,
    alias: 'variable'
  },
  'class-name': {
    pattern: /\b[A-Z][a-z][a-zA-Z0-9]*\b/
  },
  'keyword': /\b(?:transaction|imports|parameters|enum|block|message|actor|function|store|trigger|state|native|by|from|to|signed|in|on|when|auto|else|timeout|initial|terminal)\b/,
  'type': {
    pattern: /\b(?:hash|uint|int|float|peer_id|timestamp|bytes|string|bool|any|object|dict|list|map)\b|list<[^>]*>|map<[^>]*>/,
  },
  'unit': {
    pattern: /\b(?:seconds|count|fraction)\b/,
    alias: 'type'
  },
  'boolean': /\b(?:true|false)\b/,
  'null': {
    pattern: /\bnull\b/,
    alias: 'keyword'
  },
  'number': /\b\d+(?:\.\d+)?\b/,
  'operator': /->|=>|==|!=|>=|<=|[+\-*\/=<>]/,
  'punctuation': /[{}()\[\],]/
};
