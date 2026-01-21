" Vim syntax file
" Language: Omerta Transaction DSL (.omt)
" Maintainer: Generated
" Latest Revision: 2025

if exists("b:current_syntax")
  finish
endif

" Case sensitive
syn case match

" Comments - use region for proper containment
syn region omtComment start="#" end="$" contains=omtTodo
syn keyword omtTodo contained TODO FIXME XXX NOTE HACK BUG

" Strings
syn region omtString start='"' end='"' skip='\\"'

" Numbers
syn match omtNumber "\<\d\+\>"
syn match omtNumber "\<\d\+\.\d\+\>"

" Top-level declaration keywords
syn keyword omtKeyword transaction imports parameters enum block message actor function

" Block modifiers (use match for reserved words)
syn keyword omtModifier by signed native
syn match omtModifier "\<from\>"
syn match omtModifier "\<to\>"

" Actor keywords
syn keyword omtActorKeyword store trigger state

" State modifiers
syn keyword omtStateModifier initial terminal

" Transition keywords (use match for reserved words)
syn keyword omtTransition on when auto timeout
syn match omtTransition "\<else\>"

" Flow control (in expressions)
syn keyword omtConditional IF THEN ELSE
syn keyword omtLogicalOp AND OR NOT
syn keyword omtStatement RETURN

" Arrow operators
syn match omtArrow "->"
syn match omtArrow "=>"

" Comparison operators
syn match omtOperator "=="
syn match omtOperator "!="
syn match omtOperator ">="
syn match omtOperator "<="

" Primitive types
syn keyword omtType hash uint int float peer_id timestamp bytes string bool any object dict
syn match omtType "\<list<[^>]*>"
syn match omtType "\<map<[^>]*>"

" Parameter units
syn keyword omtUnit seconds count fraction

" Built-in functions (uppercase) - use match for reserved words
syn keyword omtBuiltin HASH SIGN VERIFY_SIG MULTI_SIGN RANDOM_BYTES GENERATE_ID
syn keyword omtBuiltin LENGTH CONCAT SORT HAS_KEY ABS MIN MAX
syn keyword omtBuiltin FILTER MAP
syn keyword omtBuiltin SEND BROADCAST STORE APPEND LOAD
syn keyword omtBuiltin NOW READ
syn keyword omtBuiltin CHAIN_CONTAINS_HASH CHAIN_STATE_AT CHAIN_SEGMENT VERIFY_CHAIN_SEGMENT
syn keyword omtBuiltin SEEDED_RNG SEEDED_SAMPLE
syn keyword omtBuiltin SET_EQUALS EXTRACT_FIELD COUNT_MATCHING REMOVE
syn keyword omtBuiltin SELECT_WITNESSES VERIFY_WITNESS_SELECTION
syn keyword omtBuiltin VALIDATE_LOCK_RESULT VALIDATE_TOPUP_RESULT
" Use match for reserved Vim keywords
syn match omtBuiltin "\<GET\>"
syn match omtBuiltin "\<CONTAINS\>"

" Special values
syn keyword omtConstant null true false
syn keyword omtConstant chain

" Enum values (UPPER_CASE identifiers)
syn match omtEnumValue "\<[A-Z][A-Z0-9_]\+\>"

" Actor/Type names (CamelCase)
syn match omtTypeName "\<[A-Z][a-z][a-zA-Z0-9]*\>"

" Highlight groups
hi def link omtComment Comment
hi def link omtTodo Todo
hi def link omtString String
hi def link omtNumber Number
hi def link omtKeyword Keyword
hi def link omtModifier Keyword
hi def link omtActorKeyword Keyword
hi def link omtStateModifier StorageClass
hi def link omtTransition Conditional
hi def link omtConditional Conditional
hi def link omtLogicalOp Operator
hi def link omtStatement Statement
hi def link omtOperator Operator
hi def link omtArrow Operator
hi def link omtType Type
hi def link omtUnit Type
hi def link omtBuiltin Function
hi def link omtConstant Constant
hi def link omtEnumValue Constant
hi def link omtTypeName Type

let b:current_syntax = "omt"
