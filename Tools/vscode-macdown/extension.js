// Opens Markdown files in MacDown: from the Command Palette, the editor's
// title bar and context menus, the Explorer's context menu, and ⌥⌘M.

const vscode = require("vscode");
const { execFile } = require("child_process");

// MacDown (Swift)'s bundle identifier, so the original MacDown, which has
// the same name, isn't picked by mistake.
const BUNDLE_ID = "io.github.levous.macdown-swift";

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("macdown.open", async (uri) => {
      // From a menu, the file clicked; from the palette or shortcut, the
      // active editor's.
      const document = uri
        ? vscode.workspace.textDocuments.find((d) => d.uri.toString() === uri.toString())
        : vscode.window.activeTextEditor?.document;
      const target = uri ?? document?.uri;
      if (!target) return;
      if (target.scheme !== "file") {
        vscode.window.showWarningMessage("Save the file before opening it in MacDown.");
        return;
      }
      // MacDown reads the file from disk.
      if (document?.isDirty) await document.save();
      execFile("open", ["-b", BUNDLE_ID, target.fsPath], (error) => {
        if (error) {
          vscode.window.showErrorMessage(`Couldn't open MacDown: ${error.message}`);
        }
      });
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
