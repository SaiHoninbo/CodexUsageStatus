#!/usr/bin/env bash
set -euo pipefail

# Public GitHub Release bundles must be signed by a Developer ID Application
# identity. This helper deliberately validates the requested identity before
# the package is built, while leaving candidate/local package modes untouched.
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

# Accept either the exact certificate name or its SHA-1 identity hash, but
# require the resolved keychain entry to be a Developer ID Application cert.
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
