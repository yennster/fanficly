#!/bin/sh
# Xcode Cloud runs this right after it clones the repository and before it
# opens the project. project.yml is the source of truth, and the committed
# Fanficly.xcodeproj only lists the files it had when someone last ran
# XcodeGen, so regenerate it here the same way GitHub CI does (ci.yml).
# Xcode Cloud only looks for ci_scripts/ next to the project, so this lives in
# apple/ and works from its parent folder.
set -eu

# Every Apple build uses Xcode 27 or later: an app built with an older SDK runs
# in compatibility mode on the iPhone Duo (1.11.0, built with Xcode 26.6, did).
# The workflows pick the newest Xcode (bin/xcode_cloud.py); this stops a
# workflow someone set to an older one by hand.
xcode=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
if [ "${xcode:-0}" -lt 27 ]; then
  echo "error: this build uses Xcode ${xcode:-?}; Fanficly builds need Xcode 27 or later (iPhone Duo)" >&2
  exit 1
fi

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

# The CI workflow's Mac unit tests run the app as their host, signed for
# development on a Mac Xcode Cloud never registered, so macOS refuses to launch
# it with iCloud and app-group entitlements ("Launchd job spawn failed"). The
# tests touch neither, so CI's clone drops them; the release archives keep them.
if [ "${CI_WORKFLOW:-}" = "CI" ]; then
  for key in com.apple.developer.ubiquity-kvstore-identifier com.apple.developer.icloud-container-identifiers \
             com.apple.developer.icloud-services com.apple.developer.ubiquity-container-identifiers \
             com.apple.security.application-groups; do
    /usr/libexec/PlistBuddy -c "Delete :$key" Fanficly/FanficlyMac.entitlements 2>/dev/null || true
  done
fi
