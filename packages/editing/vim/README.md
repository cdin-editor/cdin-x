# vim

Modal editing, and the `:` ex command line.

One of the two packages every bundle ships (the other is `manager`): a cdin build
copies it in, because an editor with no other modal editing isn't an editor.

It is **not** required to be self-contained. That rule existed only because an
essential package was copied *alone*, so every `require` inside it had to resolve
within its own subtree. A bundle is a *closure* now, and `manager` ships beside
this without declaring anything about it.

Vim mode knows nothing about tabs, trees, search or git. It offers seams
instead, and [`../../integration/vim/`](../../integration/vim) is where those get
filled.

[docs/extending-vim.md](../../../docs/extending-vim.md) — the seven seams and a
worked example.

**Full page:** [vim — what it does, what you press, and how it works](../../../docs/plugins/vim.md)

Inside `vimode/`, the editing grammar is four files that each do one job:
`text.lua` knows positions and ranges, `motions.lua` knows where a key sends the
caret, `textobjects.lua` knows what `i"` names, and `operators.lua` is the only
one that changes a buffer. `keys.lua` is the only one that knows a key exists.
That split is why `di"` is one rule rather than three key handlers that have to
agree.
