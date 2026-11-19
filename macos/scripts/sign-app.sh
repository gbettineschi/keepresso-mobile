#!/bin/bash
set -euo pipefail
APP="${1:?Pass the staged app bundle}"
IDENTITY="${KEEPRESSO_CODESIGN_IDENTITY:--}"
REQUIRE_STABLE="${KEEPRESSO_REQUIRE_STABLE_SIGNING:-0}"
PROFILE="${KEEPRESSO_SIGNING_PROFILE:-apple}"
KEYCHAIN="${KEEPRESSO_CODESIGN_KEYCHAIN:-}"
if [[ "$PROFILE" != apple && "$PROFILE" != project ]]; then
  echo 'Unknown signing profile; use apple or project.' >&2
  exit 2
fi
if [[ "$PROFILE" == project && "$IDENTITY" == - ]]; then
  echo 'Project signing requires its persistent certificate; ad-hoc fallback is forbidden.' >&2
  exit 2
fi
if [[ "$REQUIRE_STABLE" != 0 && "$REQUIRE_STABLE" != 1 ]]; then
  echo 'KEEPRESSO_REQUIRE_STABLE_SIGNING must be 0 or 1.' >&2
  exit 2
fi
if [[ "$REQUIRE_STABLE" == 1 && "$IDENTITY" == - ]]; then
  echo 'Stable-signing mode requires a persistent signing certificate. Set KEEPRESSO_CODESIGN_IDENTITY to its exact SHA-1 fingerprint.' >&2
  exit 2
fi
if [[ "$IDENTITY" != - && ! "$IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'KEEPRESSO_CODESIGN_IDENTITY must be the exact 40-hex certificate fingerprint; signing will not fall back to ad-hoc.' >&2
  exit 2
fi
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$PROFILE" == apple ]]; then SIGN_ARGS+=(--deep); else SIGN_ARGS+=(--timestamp=none); fi
if [[ -n "$KEYCHAIN" ]]; then
  [[ -f "$KEYCHAIN" ]] || { echo 'Configured signing keychain is unavailable.' >&2; exit 2; }
  SIGN_ARGS+=(--keychain "$KEYCHAIN")
fi
codesign "${SIGN_ARGS[@]}" "$APP"
if [[ "$IDENTITY" == - ]]; then
  echo 'Development ad-hoc signature: legacy migration may need Keychain approval once. Valid private-file loads skip Keychain; macOS privacy approvals remain OS-controlled.' >&2
  codesign --verify --deep --strict "$APP"
elif [[ "$PROFILE" == project ]]; then
  codesign --verify --deep --strict --test-requirement "=certificate leaf = H\"$IDENTITY\" and identifier \"local.keespresso.companion\"" "$APP"
  REQUIREMENT="$(codesign --display -r- "$APP" 2>&1 | sed -n -E 's/^designated => //p')"
  LOWER_IDENTITY="$(printf '%s' "$IDENTITY" | tr '[:upper:]' '[:lower:]')"
  EXPECTED="identifier \"local.keespresso.companion\" and certificate leaf = H\"$LOWER_IDENTITY\""
  if [[ "$REQUIREMENT" != "$EXPECTED" ]]; then
    echo 'Project signing requires the exact default certificate-leaf identity; broad or changed requirements are rejected.' >&2
    exit 2
  fi
else
  # Match Apple's securityd classification for the stable teamid: partition.
  # A self-signed certificate can stabilize the DR but still gets cdhash: here.
  APPLE_TEAM_REQUIREMENT='(anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists) or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.7] exists)'
  codesign --verify --deep --strict --test-requirement "=certificate leaf = H\"$IDENTITY\" and identifier \"local.keespresso.companion\" and ($APPLE_TEAM_REQUIREMENT)" "$APP"
  REQUIREMENT="$(codesign --display -r- "$APP" 2>&1 | sed -n -E 's/^designated => //p')"
  if [[ -z "$REQUIREMENT" || "$REQUIREMENT" == *$'\n'* || "$REQUIREMENT" == *cdhash* || ( "$REQUIREMENT" != *anchor* && "$REQUIREMENT" != *certificate* ) ]]; then
    echo 'The designated requirement does not establish a stable certificate identity; refusing this owner build.' >&2
    exit 2
  fi
fi
