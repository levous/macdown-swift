# Submitting MacDown to the official Homebrew cask repository

`levous-macdown.rb` is a draft for
[Homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask). The
`macdown-swift` cask in [levous/homebrew-tap](https://github.com/levous/homebrew-tap)
(written by `Tools/release.sh`) is unaffected and stays the way to install
until the official cask is accepted.

## Eligibility (checked 2026-10-08)

The draft passes every `brew audit --cask --new --online --strict` check
except notability. Homebrew's
[acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy#notability)
requires, for a self-submission by the repository owner:

- at least **90 forks, 90 watchers or 225 stars** on `levous/macdown-swift`
  (the audit itself checks the general 30/30/75 threshold), and
- a repository **at least 30 days old**, so not before **2026-11-07**.

Expect pushback as a fork:

- `macdown` (the original, 0.7.2) was disabled on 2026-09-01 because it fails
  Gatekeeper, and nobody is designated its successor.
- [`macdown-3000`](https://formulae.brew.sh/cask/macdown-3000) is an active
  official cask for another MacDown fork.
- [#288583](https://github.com/Homebrew/homebrew-cask/pull/288583), the
  `macdown-se` fork, was declined with a pointer to a personal tap.

## Why the cask looks the way it does

- **Token `levous-macdown`**: forks must be prefixed with the vendor's name
  ([Acceptable Casks](https://docs.brew.sh/Acceptable-Casks#forks-and-apps-with-conflicting-names)),
  like `domzilla-caffeine`. `name` stays the app's name, `MacDown`.
- **`conflicts_with cask: "macdown"`**: both install `/Applications/MacDown.app`.
- **`depends_on macos: :sequoia`**: the app's `LSMinimumSystemVersion` is 15.0.
- **`livecheck`** uses GitHub releases, so Homebrew's autobump finds new versions.
- **`zap`** lists only what the app creates. It leaves out
  `~/Library/Application Support/MacDown`, which the original MacDown also
  uses. Before submitting, quit MacDown with a window open and confirm
  `~/Library/Saved Application State/io.github.levous.macdown-swift.savedState`
  exists; remove that line if it doesn't.

## Submitting

Update `version` and `sha256` to the latest release first (`Tools/release.sh`
prints the checksum), then:

```sh
export HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew tap --force homebrew/cask
cd "$(brew --repository homebrew/cask)"
gh repo fork --remote
git switch -c levous-macdown
cp ~/dev/tools/macdown-swift/Tools/homebrew/levous-macdown.rb Casks/l/levous-macdown.rb

brew style --fix levous-macdown
brew audit --cask --new --online levous-macdown
brew uninstall --cask macdown-swift   # the tap cask; both install MacDown.app
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask levous-macdown
brew uninstall --cask levous-macdown

git add Casks/l/levous-macdown.rb
git commit -m "levous-macdown 1.0 (new cask)"   # no AI co-author trailer
git push -u origin levous-macdown
gh pr create --title "levous-macdown 1.0 (new cask)" --body-file ~/dev/tools/macdown-swift/Tools/homebrew/PR_BODY.md
```

Homebrew requires that commits aren't attributed to AI, that AI use is
disclosed in the PR, and that you review the cask (including `zap`) and answer
maintainer questions yourself. Only tick checkboxes in `PR_BODY.md` for steps
you actually ran.
