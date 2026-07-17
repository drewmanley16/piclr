#!/bin/sh
# Run the SwiftLint tripwires (custom regex rules in .swiftlint.yml).
# No-op with a hint if SwiftLint isn't installed, so it never blocks a local
# workflow. CI installs SwiftLint, so the rules are always enforced on PRs.
set -e

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not installed — brew install swiftlint"
  exit 0
fi

exec swiftlint --strict
