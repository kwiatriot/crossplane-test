#!/usr/bin/env bash
# Creates the aws-creds Secret in aws-lab from bootstrap/aws-credentials.ini.
# Idempotent: re-running replaces the Secret and the providers pick it up on
# their next reconcile (no pod restart needed).
set -euo pipefail
cd "$(dirname "$0")/.."
CREDS=bootstrap/aws-credentials.ini

if [ ! -f "$CREDS" ]; then
  echo "ERROR: $CREDS not found. Copy bootstrap/aws-credentials.ini.template and fill it in." >&2
  exit 1
fi
if grep -q 'PASTE CREDS HERE' "$CREDS"; then
  echo "ERROR: $CREDS still contains the <PASTE CREDS HERE> placeholder." >&2
  exit 1
fi

kubectl create secret generic aws-creds \
  --namespace aws-lab \
  --from-file=credentials="$CREDS" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret aws-lab/aws-creds updated."
