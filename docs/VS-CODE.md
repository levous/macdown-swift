# Using MacDown with VS Code

Edit Markdown in VS Code and preview it in MacDown. The **Open in MacDown**
extension opens the current file in MacDown. Leave its window open next to VS
Code: MacDown reloads the file whenever VS Code saves it, as long as the
MacDown window has no unsaved changes of its own. The preview updates when you
save, not as you type.

## Install the extension

The extension lives in this repository, in `Tools/vscode-macdown`. It needs
Node.js to package. From the repository's root:

```sh
cd Tools/vscode-macdown
npx --yes @vscode/vsce package --out /tmp/open-in-macdown.vsix
code --install-extension /tmp/open-in-macdown.vsix
```

If the `code` command is missing, run **Shell Command: Install 'code' command
in PATH** from VS Code's Command Palette (⇧⌘P). Or install the `.vsix` from
the Extensions view: **⋯ ▸ Install from VSIX…**.

Reload VS Code's windows (**Developer: Reload Window**) if the command doesn't
show up right away.

## Use it

In a Markdown file, any of these opens it in MacDown:

- **⌥⌘M**
- **MacDown: Open in MacDown** in the Command Palette
- the preview button in the editor's title bar
- **Open in MacDown** in the context menu of the editor, its tab, or the
  file in the Explorer

Unsaved changes are saved first, since MacDown reads the file from disk. The
extension opens MacDown by its bundle identifier, so it never picks the
original MacDown by mistake.

To use a different shortcut, change it in **Preferences: Open Keyboard
Shortcuts** (search for "Open in MacDown").

## Without the extension

A VS Code task does the same from the keyboard, without menu items. It needs
the `macdown` command, which Homebrew installs with the app (otherwise link it
as the [README](../README.md) describes).

1. Run **Tasks: Open User Tasks** (choose **Others** if it asks for a
   template) and add this task:

   ```json
   {
       "version": "2.0.0",
       "tasks": [
           {
               "label": "Open in MacDown",
               "type": "shell",
               "command": "macdown",
               "args": ["${file}"],
               "presentation": { "reveal": "never", "panel": "shared" },
               "problemMatcher": []
           }
       ]
   }
   ```

2. Run **Preferences: Open Keyboard Shortcuts (JSON)** and add:

   ```json
   {
       "key": "alt+cmd+m",
       "command": "workbench.action.tasks.runTask",
       "args": "Open in MacDown",
       "when": "editorLangId == markdown"
   }
   ```

If the task says "macdown: command not found", use the command's full path
(`/opt/homebrew/bin/macdown` with Homebrew). Unlike the extension, the task
doesn't save the file first.

## Troubleshooting

- **The file opens in a different copy of MacDown** (such as a build from
  Xcode): every copy of the app registers itself with macOS. Remove the
  other copies, or see "Checking the running app" in
  [ARCHITECTURE.md](ARCHITECTURE.md).
- **The preview doesn't update after saving:** MacDown only reloads a file
  when its window has no unsaved changes. If you also typed in MacDown, it
  asks whether to keep your changes or revert to the file.
