#!/bin/bash
set -euo pipefail
APP="${1:?Pass the staged app bundle}"
IDENTITY="${KEEPRESSO_CODESIGN_IDENTITY:--}"
REQUIRE_STABLE="${KEEPRESSO_REQUIRE_STABLE_SIGNING:-0}"
if [[ "$REQUIRE_STABLE" != 0 && "$REQUIRE_STABLE" != 1 ]]; then
  echo 'KEEPRESSO_REQUIRE_STABLE_SIGNING must be 0 or 1.' >&2
  exit 2
fi
if [[ "$REQUIRE_STABLE" == 1 && "$IDENTITY" == - ]]; then
  echo 'Owner updates require a persistent signing certificate. Set KEEPRESSO_CODESIGN_IDENTITY to its exact SHA-1 fingerprint.' >&2
  exit 2
fi
if [[ "$IDENTITY" != - && ! "$IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo 'KEEPRESSO_CODESIGN_IDENTITY must be the exact 40-hex certificate fingerprint; signing will not fall back to ad-hoc.' >&2
  exit 2
fi
codesign --force --deep --sign "$IDENTITY" "$APP"
if [[ "$IDENTITY" == - ]]; then
  echo 'Development ad-hoc signature: updates change app identity and may repeat Keychain approvals. Use a persistent certificate for owner updates.' >&2
  codesign --verify --deep --strict "$APP"
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
