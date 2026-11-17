#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
./node_modules/.bin/wrangler d1 migrations apply clipnote --remote
./node_modules/.bin/wrangler deploy
