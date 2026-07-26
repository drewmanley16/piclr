# Conventions

The rules that keep the codebase consistent. The mechanical subset is enforced
by SwiftLint tripwires (below); the rest is reviewed by hand.

## Workflow

- **New feature = new branch off `main`, one PR.**
- There is no test target. "Verification" means: `xcodebuild` succeeds +
  screenshot the running simulator (`xcrun simctl io booted screenshot`) when
  there's UI. SourceKit "Cannot find type … in scope" diagnostics while editing
  are usually transient cross-file noise — trust the `xcodebuild` result.
- When screenshot-verifying a screen you can't tap to, a common pattern is a
  temporary `TabView(selection: .constant(<tab>))` + `.tag()` hook or an
  `.onAppear` seed — **always revert these temp hooks before committing.**
- Run `scripts/lint.sh` before pushing; CI runs the same tripwires with
  `--strict` on every PR.

## UI consistency contract

- **Person rows use `IdentityRow`** (`DesignSystem.swift`), or `ProfileAvatar`
  directly when the row shape genuinely diverges (leaderboard ranks, comment
  replies). Models representing people carry `PersonRef`
  (`ProfileModels.swift`).
- **Avatars always navigate when a profile exists.** `ProfileAvatar` links by
  default; `unlinked: true` is the documented opt-out and needs a reason
  (inside an enclosing link/tappable card, own-profile, pickers). Use
  `guest:` / `preview:` for profile-less avatars.
- **Navigate to profiles via `ProfileLink`**, never by constructing
  `OtherProfileView` directly (tripwire-enforced).
- **Any sheet containing navigable people must use `ProfileNavigationStack`**
  (`OtherProfileView.swift`), not a bare `NavigationStack` — otherwise
  `openProfile` resolves to the presenting screen's stack and pushes *behind*
  the sheet.
- **Every list screen ships skeleton loading (`SkeletonList`) + an empty state
  + `.refreshable`.**
- **User-initiated state changes fire `Haptics`** (impact / tap / success per
  `Haptics.swift`'s doc).
- **Colors, spacing, and fonts come from `Theme`** (`DesignSystem.swift`) — no
  hardcoded values. Design language is all-black + electric-lime; cards use
  `cardStyle()`.

## SwiftLint tripwires

`.swiftlint.yml` runs **only** custom regex rules — tripwires for the contract
above, not a style linter. Current rules:

| Rule | Forbids | Instead |
|---|---|---|
| `avatar_nil_url` | `ProfileAvatar(url: nil` | `ProfileAvatar(guest:)` / `(preview:)` |
| `hardcoded_color` | `Color(red:)`, `Color.white/.black`, `.foregroundColor(.` | `Theme` tokens |
| `inline_dateformatter` | per-call `DateFormatter()` construction | cached `static let` formatters |
| `manual_profile_nav` | direct `OtherProfileView(` construction | `ProfileLink` |

Each rule lands with zero violations; if a new rule is added, verify the same.
Legitimate exceptions go in the rule's `excluded:` list with a comment
explaining why.

## Code style

- Match the surrounding SwiftUI style: small computed subviews, `Theme` tokens,
  `cardStyle()`.
- Comments state constraints the code can't show (why a guard exists, what an
  ordering protects) — not narration of what the next line does.
- Analytics events go through `Analytics` (see `Analytics.swift`'s taxonomy),
  never raw PostHog capture calls.
- New backend calls become methods on the matching `AppStore+*.swift`
  extension; views stay networking-free.
