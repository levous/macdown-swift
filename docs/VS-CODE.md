# Using MacDown with VS Code

Edit Markdown in VS Code and preview it in MacDown. A keyboard shortcut opens
the current file in MacDown. Leave its window open next to VS Code: MacDown
reloads the file whenever VS Code saves it, as long as the MacDown window has
no unsaved changes of its own. The preview updates when you save, not as you
type.

## Before you start

You need the `macdown` command. Homebrew installs it with the app. Otherwise,
link it as the [README](../README.md) describes. Check that it's there:

```sh
macdown --version
```

## 1. Add a task

In VS Code, open the Command Palette (⇧⌘P) and run **Tasks: Open User Tasks**.
Choose **Others** if it asks for a template. A user task works in every
workspace. Make the file contain this task (add it to the `tasks` list if you
already have tasks):

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

`"reveal": "never"` keeps the terminal panel from opening each time.

## 2. Add a keyboard shortcut

Run **Preferences: Open Keyboard Shortcuts (JSON)** from the Command Palette
and add this entry to the list:

```json
{
    "key": "alt+cmd+m",
    "command": "workbench.action.tasks.runTask",
    "args": "Open in MacDown",
    "when": "editorLangId == markdown"
}
```

Now ⌥⌘M opens the Markdown file you're editing in MacDown. The `when` clause
limits the shortcut to Markdown files, so ⌥⌘M keeps its usual meaning
elsewhere. Pick another key if ⌥⌘M is already taken.

Without the shortcut, you can still run the task with **Tasks: Run Task ▸
Open in MacDown**.

## Troubleshooting

- **"macdown: command not found"** in the task's terminal: VS Code's shell
  can't find the command. Use its full path in the task
  (`/opt/homebrew/bin/macdown` with Homebrew), or replace the command with
  `open` and `"args": ["-a", "MacDown", "${file}"]`.
- **The file opens in a different copy of MacDown** (such as a build from
  Xcode): every copy of the app registers itself with macOS. Remove the
  other copies, or see "Checking the running app" in
  [ARCHITECTURE.md](ARCHITECTURE.md).
- **The preview doesn't update after saving:** MacDown only reloads a file
  when its window has no unsaved changes. If you also typed in MacDown, it
  asks whether to keep your changes or revert to the file.
