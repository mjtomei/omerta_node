/**
 * Omerta Transaction DSL (.omt) language definition for highlight.js
 *
 * Usage with highlight.js:
 *   hljs.registerLanguage('omt', require('./omt.js'));
 *
 * Or in browser:
 *   <script src="omt.js"></script>
 *   hljs.registerLanguage('omt', hljsOmt);
 */

function hljsOmt(hljs) {
  const KEYWORDS = {
    keyword: [
      'transaction', 'imports', 'parameters', 'enum', 'block', 'message',
      'actor', 'function', 'store', 'trigger', 'state', 'native',
      'by', 'from', 'to', 'signed', 'in',
      'on', 'when', 'auto', 'else', 'timeout',
      'initial', 'terminal'
    ],
    built_in: [
      'HASH', 'SIGN', 'VERIFY_SIG', 'MULTI_SIGN', 'RANDOM_BYTES', 'GENERATE_ID',
      'LENGTH', 'CONCAT', 'SORT', 'HAS_KEY', 'ABS', 'MIN', 'MAX',
      'FILTER', 'MAP', 'GET', 'CONTAINS', 'REMOVE',
      'SEND', 'BROADCAST', 'STORE', 'APPEND', 'LOAD',
      'NOW', 'READ',
      'CHAIN_CONTAINS_HASH', 'CHAIN_STATE_AT', 'CHAIN_SEGMENT', 'VERIFY_CHAIN_SEGMENT',
      'SEEDED_RNG', 'SEEDED_SAMPLE',
      'SET_EQUALS', 'EXTRACT_FIELD', 'COUNT_MATCHING',
      'SELECT_WITNESSES', 'VERIFY_WITNESS_SELECTION',
      'VALIDATE_LOCK_RESULT', 'VALIDATE_TOPUP_RESULT',
      'IF', 'THEN', 'ELSE', 'AND', 'OR', 'NOT', 'RETURN'
    ],
    type: [
      'hash', 'uint', 'int', 'float', 'peer_id', 'timestamp',
      'bytes', 'string', 'bool', 'any', 'object', 'dict', 'list', 'map'
    ],
    literal: [
      'null', 'true', 'false'
    ]
  };

  const UNITS = {
    scope: 'type',
    match: /\b(seconds|count|fraction)\b/
  };

  const TYPE_NAME = {
    scope: 'title.class',
    match: /\b[A-Z][a-z][a-zA-Z0-9]*\b/
  };

  const ENUM_VALUE = {
    scope: 'variable.constant',
    match: /\b[A-Z][A-Z0-9_]+\b/
  };

  const ARROW = {
    scope: 'operator',
    match: /->|=>/
  };

  const COMMENT = hljs.COMMENT('#', '$');

  const STRING = {
    scope: 'string',
    begin: '"',
    end: '"',
    contains: [hljs.BACKSLASH_ESCAPE]
  };

  const NUMBER = {
    scope: 'number',
    match: /\b\d+(\.\d+)?\b/
  };

  const LIST_TYPE = {
    scope: 'type',
    match: /\blist<[^>]*>/
  };

  const MAP_TYPE = {
    scope: 'type',
    match: /\bmap<[^>]*>/
  };

  return {
    name: 'Omerta Transaction DSL',
    aliases: ['omt'],
    case_insensitive: false,
    keywords: KEYWORDS,
    contains: [
      COMMENT,
      STRING,
      NUMBER,
      UNITS,
      LIST_TYPE,
      MAP_TYPE,
      TYPE_NAME,
      ENUM_VALUE,
      ARROW
    ]
  };
}

// CommonJS export
if (typeof module !== 'undefined' && module.exports) {
  module.exports = hljsOmt;
}

// Browser global
if (typeof window !== 'undefined') {
  window.hljsOmt = hljsOmt;
}
