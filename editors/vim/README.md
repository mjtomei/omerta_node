# Vim Support for Omerta Transaction DSL (.omt)

Syntax highlighting, filetype detection, and indentation for `.omt` files.

## Installation

### Option 1: Symlink (recommended for development)

```bash
# Create vim directories if they don't exist
mkdir -p ~/.vim/syntax ~/.vim/ftdetect ~/.vim/indent

# Symlink the files
ln -sf $(pwd)/syntax/omt.vim ~/.vim/syntax/omt.vim
ln -sf $(pwd)/ftdetect/omt.vim ~/.vim/ftdetect/omt.vim
ln -sf $(pwd)/indent/omt.vim ~/.vim/indent/omt.vim
```

### Option 2: Copy files

```bash
mkdir -p ~/.vim/syntax ~/.vim/ftdetect ~/.vim/indent
cp syntax/omt.vim ~/.vim/syntax/
cp ftdetect/omt.vim ~/.vim/ftdetect/
cp indent/omt.vim ~/.vim/indent/
```

### Option 3: Vim 8+ packages

```bash
mkdir -p ~/.vim/pack/omerta/start/omt-syntax
cp -r syntax ftdetect indent ~/.vim/pack/omerta/start/omt-syntax/
```

### Neovim

For Neovim, use `~/.config/nvim/` instead of `~/.vim/`.

## Features

- **Syntax highlighting** for:
  - Keywords: `transaction`, `imports`, `parameters`, `enum`, `block`, `message`, `actor`, `function`
  - State machine: `state`, `trigger`, `store`, `initial`, `terminal`
  - Transitions: `on`, `when`, `auto`, `else`, `timeout`, `->`, `=>`
  - Types: `hash`, `uint`, `peer_id`, `timestamp`, `list<>`, `map<>`, etc.
  - Built-in functions: `HASH`, `SEND`, `STORE`, `FILTER`, `MAP`, etc.
  - Comments, strings, numbers

- **Auto-detection** of `.omt` files

- **Indentation** support for nested blocks

## Screenshot

```omt
# Transaction definition with syntax highlighting
transaction 00 "Escrow Lock" "Description here"

parameters (
    TIMEOUT = 30 seconds "How long to wait"
)

actor Consumer "The paying party" (
    state IDLE initial "Waiting"
    state DONE terminal "Complete"

    IDLE -> DONE on RESPONSE when valid (
        STORE(result, message.data)
        SEND(provider, ACK)
    )
)
```
