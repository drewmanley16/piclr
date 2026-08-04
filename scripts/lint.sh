#!/bin/sh
# Pre-push checks. CI calls this too, so local and CI can't diverge.
#
# Heads up: as of this commit, GitHub Actions has never actually run on this
# repository — zero workflow runs ever recorded, across every workflow and
# both runner OSes. Until that's fixed, running this script by hand is the
# only thing that enforces any of the checks below.
#
# Three checks, cheapest first:
#   1. `Shared/` stays dependency-free (Foundation only).
#   2. The SwiftLint custom regex rules in .swiftlint.yml.
#   3. PickleballAI.xcodeproj matches project.yml (XcodeGen drift).
#
# SwiftLint is pinned by .swiftlint-version so every machine runs the same
# rules — the custom rules are verified to have zero violations on the day
# each lands, and a different linter build can change regex semantics or which
# files it walks. A missing tool is a warning, not a failure, so this never
# blocks a local workflow.
set -e

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

status=0

# --- 1. Shared/ compiles into both the app and the watch target, so anything
# it imports must exist on both platforms. Foundation only, by contract. ---
stray_imports=$(
  grep -rh '^import ' Shared --include='*.swift' \
    | sort -u \
    | grep -v '^import Foundation$' \
    || true
)
if [ -n "$stray_imports" ]; then
  echo "error: Shared/ must be dependency-free (Foundation only)."
  echo "       It compiles into both the app and the watch target."
  echo "       Unexpected imports:"
  echo "$stray_imports" | sed 's/^/         /'
  status=1
else
  echo "ok: Shared/ is dependency-free"
fi

# --- 2. SwiftLint tripwires ---
if ! command -v swiftlint >/dev/null 2>&1; then
  echo "warning: swiftlint not installed — skipping tripwires."
  echo "         brew install swiftlint  (pin: $(cat .swiftlint-version))"
else
  pinned=$(cat .swiftlint-version)
  installed=$(swiftlint version)
  if [ "$pinned" != "$installed" ]; then
    echo "warning: swiftlint $installed installed, .swiftlint-version pins $pinned."
  fi
  # --quiet suppresses the per-file progress but still prints violations, so
  # silence here means clean. Say so explicitly rather than leaving the reader
  # wondering whether it ran.
  if swiftlint --strict --quiet; then
    echo "ok: swiftlint tripwires ($(find PickleballAI PickleballAIWidget PickleballAIWatch Shared -name '*.swift' | wc -l | tr -d ' ') files)"
  else
    status=1
  fi
fi

# --- 3. XcodeGen drift. PickleballAI.xcodeproj is generated from project.yml
# and CLAUDE.md opens with "do not hand-edit the .xcodeproj". `generate` is
# idempotent, so when the project is already in sync this rewrites nothing;
# it only touches the file when there is real drift, which is exactly the
# case you want surfaced. ---
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "warning: xcodegen not installed — skipping project drift check."
  echo "         brew install xcodegen"
else
  xcodegen generate --quiet 2>/dev/null || xcodegen generate >/dev/null
  if git diff --quiet -- PickleballAI.xcodeproj; then
    echo "ok: PickleballAI.xcodeproj matches project.yml"
  else
    echo "error: PickleballAI.xcodeproj was out of sync with project.yml."
    echo "       It has been regenerated — review and commit the result."
    status=1
  fi
fi

exit $status
