MacDown is an open source Markdown editor with live preview, a Swift/SwiftUI
port of the original MacDown (`macdown`, disabled for failing Gatekeeper). This
build is signed with a Developer ID and notarized. The token is vendor-prefixed
because it is a fork, and it conflicts with `macdown`, which installs an app at
the same path.

-----

After making any changes to a cask, existing or new, verify:

- [ ] The submission is for [a stable version](https://docs.brew.sh/Acceptable-Casks#stable-versions) or [documented exception](https://docs.brew.sh/Acceptable-Casks#but-there-is-no-stable-version).
- [ ] `brew audit --cask --online levous-macdown` is error-free.
- [ ] `brew style --fix levous-macdown` reports no offenses.

Additionally, if adding a new cask:

- [ ] Named the cask according to the [token reference](https://docs.brew.sh/Cask-Cookbook#token-reference).
- [ ] Checked the cask was not [already refused](https://github.com/search?q=repo%3AHomebrew%2Fhomebrew-cask+is%3Aclosed+is%3Aunmerged+levous-macdown&type=pullrequests).
- [ ] `brew audit --cask --new levous-macdown` worked successfully.
- [ ] `HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask levous-macdown` worked successfully.
- [ ] `brew uninstall --cask levous-macdown` worked successfully.

-----

- [ ] I did not use AI/LLM to create this PR, or I disclosed the tool/model below and reviewed its output, including [`zap` stanza](https://docs.brew.sh/Cask-Cookbook#stanza-zap) paths; I did not attribute commits to AI and will answer maintainer questions and review comments myself without AI/LLM.

The cask was drafted with Claude (Anthropic) in Claude Code, which also ran
`brew style`, `brew audit --cask --new --online --strict` and `brew livecheck`
against it. I reviewed every stanza, verified the `zap` paths against the files
the app creates on my Mac, and ran the install and uninstall checks above myself.
