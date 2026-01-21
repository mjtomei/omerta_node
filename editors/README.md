# Editor Support for Omerta Transaction DSL (.omt)

Syntax highlighting for `.omt` files across different editors and platforms.

## Vim / Neovim

See [vim/README.md](vim/README.md) for installation instructions.

## highlight.js (for web/markdown)

Used by many static site generators (Jekyll, Hugo, Docusaurus, etc.) and documentation tools.

```html
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<script src="path/to/highlightjs/omt.js"></script>
<script>
  hljs.registerLanguage('omt', hljsOmt);
  hljs.highlightAll();
</script>
```

With Node.js:

```javascript
const hljs = require('highlight.js');
const hljsOmt = require('./highlightjs/omt.js');
hljs.registerLanguage('omt', hljsOmt);
```

## Prism.js (for web/markdown)

Used by many documentation tools (Docusaurus, Gatsby, etc.).

```html
<script src="https://cdnjs.cloudflare.com/ajax/libs/prism/1.29.0/prism.min.js"></script>
<script src="path/to/prismjs/omt.js"></script>
```

Then use in markdown:

~~~markdown
```omt
actor Consumer "The paying party" (
    state IDLE initial "Waiting"
    state DONE terminal "Complete"
)
```
~~~

## GitHub / GitLab

GitHub and GitLab don't support custom languages. As a workaround, you can use:
- `text` for no highlighting
- `python` or `ruby` for approximate highlighting (not recommended)

For proper rendering on GitHub Pages, use Jekyll with highlight.js or Prism.js.
