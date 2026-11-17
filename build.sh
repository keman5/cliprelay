#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if command -v go >/dev/null 2>&1; then go clean -cache; fi
npm run lint
npm test
npm version patch --no-git-tag-version >/dev/null
./node_modules/.bin/vite build
