#!/usr/bin/env bash
set -euo pipefail

# Public GitHub Release bundles require a stable Developer ID Application
# identity. Candidate and local package modes do not call this helper.
IDENTITY="${1:-}"

if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "release mode requires a non-empty Developer ID Application identity" >&2
  exit 3
fi

IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -z "$IDENTITIES" ]]; then
  echo "release identity is not available in the local keychain: $IDENTITY" >&2
  exit 3
fi

# Accept the exact certificate name or its SHA-1 identity hash, but only when
# the resolved keychain entry is a Developer ID Application certificate.
MATCH="$(printf '%s\n' "$IDENTITIES" | grep -F '"'"$IDENTITY"'"' || true)"
if [[ -z "$MATCH" ]]; then
  MATCH="$(printf '%s\n' "$IDENTITIES" | grep -F " $IDENTITY " || true)"
fi

if [[ -z "$MATCH" ]]; then
  echo "release identity is not available in the local keychain: $IDENTITY" >&2
  exit 3
fi

if ! printf '%s\n' "$MATCH" | grep -Fq 'Developer ID Application:'; then
  echo "release identity must be Developer ID Application; refusing: $IDENTITY" >&2
  exit 3
fi

printf '%s\n' "$MATCH"
