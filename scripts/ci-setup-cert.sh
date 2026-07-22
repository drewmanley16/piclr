#!/usr/bin/env bash
# One-time setup for the TestFlight GitHub Actions pipeline.
#
# Exports your Apple Distribution certificate + private key from the login
# keychain as a .p12 and stores it (with a random password) as the
# DIST_CERT_P12 / DIST_CERT_PASSWORD repo secrets the workflow needs.
#
# macOS will prompt you to allow the export and enter your login password —
# click "Allow" (or "Always Allow"). Run this from the repo root:
#   scripts/ci-setup-cert.sh
set -euo pipefail

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

TMP="$(mktemp -d)"
P12="$TMP/dist.p12"
PW="$(uuidgen)"

echo "==> Exporting Apple Distribution identity (approve the keychain prompt)…"
security export -t identities -f pkcs12 -P "$PW" -o "$P12"

echo "==> Uploading secrets to GitHub…"
base64 -i "$P12" | gh secret set DIST_CERT_P12
printf '%s' "$PW" | gh secret set DIST_CERT_PASSWORD

rm -rf "$TMP"
echo "==> Done. DIST_CERT_P12 and DIST_CERT_PASSWORD are set."
echo "    The TestFlight workflow is now fully configured."
