# Editors

## VS Code

`editors/vscode/` in the repository is a VS Code extension with syntax highlighting, the
language server and the debugger.

```console
$ cd editors/vscode
$ npm install
$ npx @vscode/vsce package
$ code --install-extension auk-lang-0.1.0.vsix
```

It finds `auk` on the `PATH` or in `~/.auk/bin`; the setting `auk.path` names another binary.

What you get:

- **Diagnostics as you type**, with error codes and notes. Files are checked in their project,
  so errors in other modules show up on those files.
- **Quick fixes** from the compiler's fix-its (`Cmd+.` / `Ctrl+.`): a missing `?` or `&`, an
  undeclared effect, a misspelled name, a missing clause.
- **Hover** for the type of any expression, and signatures with their `///` docs.
- **Go to definition** across modules and dependencies.
- **Format Document**, and the **Outline** view.
- **Run**, **Run with Arguments**, **Test** and **Debug** buttons in the editor's title bar.
- **Debugging** (`F5`): breakpoints, conditional breakpoints, stepping, the call stack with one
  thread per task, expandable locals, hover, and Auk expressions in Watch and the Debug
  Console.

Hover and type-based navigation need a program that type-checks. Other modules are read from
disk, so save a file for its changes to be seen from another.

## Any other editor

Two standard protocols cover everything above:

| command | protocol | provides |
|---|---|---|
| `auk lsp` | Language Server Protocol, over stdio | diagnostics, quick fixes, hover, go to definition, formatting, document symbols |
| `auk dap` | Debug Adapter Protocol, over stdio | launch, breakpoints, stepping, stack, variables, evaluate |

Point your editor's LSP client at `auk lsp` for files matching `*.auk`, with the project root
at the nearest `raft.toml`. For format-on-save without LSP, pipe the buffer through
`auk fmt -`.

A DAP launch configuration takes `program`, `args`, `cwd` and `stopOnEntry`:

```json
{ "type": "auk", "request": "launch", "name": "Debug", "program": "${file}",
  "cwd": "${fileDirname}", "args": [], "stopOnEntry": false }
```

The TextMate grammar in `editors/vscode/syntaxes/auk.tmLanguage.json` works in any editor that
reads TextMate grammars.
