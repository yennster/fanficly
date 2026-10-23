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

# The committed Signing.xcconfig has no team, so a device build (the release
# archive, bin/xcode-cloud-release.py) signs with the team Xcode Cloud builds
# for. Only this clone changes; nothing is committed.
if [ -n "${CI_TEAM_ID:-}" ]; then
  sed -i '' "s/^DEVELOPMENT_TEAM =.*/DEVELOPMENT_TEAM = ${CI_TEAM_ID}/" Signing.xcconfig
fi
