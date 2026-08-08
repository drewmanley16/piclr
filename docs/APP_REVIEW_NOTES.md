# App Review notes — piclr (com.pickleball.ai)

Source of truth for the **App Review Information → Notes** field in App Store
Connect, and for replies in Resolution Center. Keep it in sync with the app: the
1.0 rejection under guideline 2.1(b) happened with this field empty, so a
reviewer who landed on the Home tab had nothing telling them where the
subscription lived.

Paste the block below into **App Review Information → Notes** on every version.

---

## Notes field (paste verbatim)

```
DEMO ACCOUNT
Phone: +1 555 555 0123
Verification code: 424242
The sign-in screen asks for a phone number, then a 6-digit SMS code. This test
number does not send a real SMS — enter the code above directly.

WHERE TO FIND THE IN-APP PURCHASES (Pro Annual / Pro Monthly)
Fastest path, works on any account including a brand-new one:
1. Sign in with the demo account above.
2. Tap the "Profile" tab (bottom right).
3. Tap the gear icon in the top-right corner.
4. Tap the "piclr PRO" row at the top of Settings, directly under your name.
   The paywall opens with both subscriptions: Pro Annual ($29.99/year) and
   Pro Monthly ($4.99/month), each with a 7-day free trial.

Alternate path: on the Profile tab, tap the "piclr PRO" banner shown near the
top of the screen. Locked Pro features elsewhere (Insights, Rivalry insights,
Weekly wrap, Leaderboard filters, history ranges beyond one month) open the
same paywall, but those cards only appear once the account has logged enough
sessions, so the two paths above are the reliable ones.

"Restore purchases" is in Settings below the menu, and on the paywall footer.

There are no storefront or device restrictions on the In-App Purchases.

OTHER NOTES
- The app is iPhone-only and portrait-only.
- Account deletion: Settings → Account → Delete Account.
- Terms of Use and Privacy Policy are readable in-app at Settings → Legal, and
  must be affirmatively accepted on the sign-up screen.
- Report and Block are available on every post and profile via the "..." menu.
```

---

## Resolution Center reply for the 2.1(b) rejection

```
Thank you for the review.

The In-App Purchases were reachable in the previous build, but only from
feature cards that require the account to have logged sessions first, so a new
review account would not have seen them. We have fixed that and we apologize
for the missing steps.

In the new build we added a permanent "piclr PRO" row at the top of Settings
that does not depend on any account data, and the Pro banner on the Profile tab
is now always shown to non-subscribers.

Steps to locate the In-App Purchases:
1. Sign in with the demo account: phone +1 555 555 0123, code 424242.
   (This is a test number — no real SMS is sent; enter the code directly.)
2. Tap the "Profile" tab at the bottom right.
3. Tap the gear icon in the top-right corner.
4. Tap the "piclr PRO" row at the top of Settings.

The paywall shows both In-App Purchases — Pro Annual ($29.99/year) and Pro
Monthly ($4.99/month), each with a 7-day free trial — along with Restore
Purchases, Terms of Use, and Privacy Policy.

We do not restrict the In-App Purchases by storefront or device configuration.
Both subscriptions are submitted with this version and the Paid Applications
Agreement is active.

Please let us know if anything else would help.
```

Adjust the Paid Applications Agreement sentence if that agreement is not in fact
active — see the release checklist in `docs/RELEASE.md`.
