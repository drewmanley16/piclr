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

---

## App Store Connect changes that still need a human

The code fixes cover the app. These are metadata, and the API key we hold can
read them but changing them is a deliberate act — do them in the ASC UI before
resubmitting.

**Blocking / high risk**

- [ ] **App Review Information → Notes: paste the block above.** It was empty on
      the rejected submission. This is the single highest-value change.
- [ ] **Guideline 3.1.2 — subscription disclosure in the App Store description.**
      An app with auto-renewable subscriptions must state, in the description
      metadata, the subscription title, length, and price, plus links to both
      the Terms of Use (EULA) and the Privacy Policy. The current description
      ends with a Terms of Use link only. Append something like:

      > piclr Pro is an auto-renewing subscription: $4.99/month or $29.99/year,
      > each with a 7-day free trial. Payment is charged to your Apple ID at
      > confirmation of purchase. It renews automatically unless cancelled at
      > least 24 hours before the end of the period; manage or cancel in your
      > Apple ID settings.
      > Terms of Use: https://pickleball-ai-web.vercel.app/terms
      > Privacy Policy: https://pickleball-ai-web.vercel.app/privacy

- [ ] **Guideline 2.3.1 — "AI recaps" in the IAP metadata.** The Pro Annual
      subscription description reads "AI recaps, rivalry insights & full
      history". The app has no AI feature. Change it to match what ships, e.g.
      "Play insights, rivalry breakdowns & full history". The in-app copy is
      already fixed.
- [ ] **Confirm the Paid Applications Agreement is active** (Business →
      Agreements). Apple raised it in the rejection. Paid IAPs will not function
      without it, and no code change can compensate.

**Worth fixing while you are in there**

- [ ] **Support URL points at a Terms page** (`https://piclr.vercel.app/terms`).
      Guideline 1.5 expects a page with actual support information. Point it at a
      support page, or at minimum one that publishes the support email that
      Settings → Contact & Support already uses.
- [ ] **Two domains in use** — `piclr.vercel.app` for marketing, and
      `pickleball-ai-web.vercel.app` for Terms and Privacy. Both resolve, but
      consolidating avoids a reviewer wondering which is the real publisher.
- [ ] **The description still says "pickleball.ai" throughout** while the app,
      the App Store name, and the home screen all say "piclr". Not a rejection
      on its own — the App Store name and `CFBundleDisplayName` do match, which
      is what guideline 2.3.8 tests — but it reads as stale.

**Verified already in place, no action needed**

- Both subscriptions are attached to the version and sit in `IN_REVIEW`, with
  localizations, prices, and the required review screenshot present.
- Build 134 is attached and `VALID`; the resubmission should be build 135+.
- Account deletion, Report, Block, an affirmative Terms gate at sign-up, and
  in-app Terms/Privacy documents are all shipping (guidelines 1.2 and 5.1.1(v)).
- `ITSAppUsesNonExemptEncryption`, portrait-only orientation, iPhone-only device
  family, and the privacy manifest are all declared.
- App Store name is "piclr", matching `CFBundleDisplayName`.
- HealthKit is fully removed, with a lint tripwire preventing its return.
