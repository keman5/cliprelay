#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
w=../../node_modules/.bin/wrangler
private_dir="${CLIPRELAY_CONFIG_DIR:-$HOME/.config/cliprelay-test}"
umask 077
mkdir -p "$private_dir"
secrets="$private_dir/worker-secrets.json"
if [[ ! -e "$secrets" ]]; then
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({RELAY_TOKEN:require("crypto").randomBytes(32).toString("hex")}),{mode:0o600,flag:"wx"})' "$secrets"
fi
if ! "$w" r2 bucket list | awk '/^name:/ {print $2}' | grep -Fx 'cliprelay-test-ciphertext' >/dev/null; then
  "$w" r2 bucket create cliprelay-test-ciphertext
fi
rules=$("$w" r2 bucket lifecycle list cliprelay-test-ciphertext)
if ! awk '/^name:/ {print $2}' <<<"$rules" | grep -Fx 'expire-queue' >/dev/null; then
  "$w" r2 bucket lifecycle add cliprelay-test-ciphertext expire-queue v1/ --expire-days 7 --force
fi
"$w" deploy --secrets-file "$secrets"
