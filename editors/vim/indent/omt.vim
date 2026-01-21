" Vim indent file
" Language: Omerta Transaction DSL (.omt)

if exists("b:did_indent")
  finish
endif
let b:did_indent = 1

setlocal indentexpr=GetOmtIndent()
setlocal indentkeys=0{,0},0),0],!^F,o,O

if exists("*GetOmtIndent")
  finish
endif

function! GetOmtIndent()
  let lnum = prevnonblank(v:lnum - 1)
  if lnum == 0
    return 0
  endif

  let line = getline(lnum)
  let cline = getline(v:lnum)
  let ind = indent(lnum)

  " Increase indent after opening paren/brace that isn't closed
  if line =~ '(\s*$' || line =~ '{\s*$'
    let ind += shiftwidth()
  endif

  " Decrease indent for closing paren/brace
  if cline =~ '^\s*)'  || cline =~ '^\s*}'
    let ind -= shiftwidth()
  endif

  " Handle 'else' at same level as transition
  if cline =~ '^\s*)\s*else'
    let ind -= shiftwidth()
  endif

  return ind
endfunction
