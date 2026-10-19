#!/bin/sh
# Xcode Cloud runs this right after it clones the repository and before it
# opens the project. project.yml is the source of truth, and the committed
# Fanficly.xcodeproj only lists the files it had when someone last ran
# XcodeGen, so regenerate it here the same way GitHub CI does (ci.yml).
# Xcode Cloud only looks for ci_scripts/ next to the project, so this lives in
# apple/ and works from its parent folder.
set -eu

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install xcodegen

cd "$(dirname "$0")/.."
xcodegen generate
