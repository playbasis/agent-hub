#!/bin/sh
# Repository hygiene: fails on key-shaped strings, real home-folder paths and
# files that must never be committed. Run by `make check`.
#
# Terms that must never appear (a name, a client, an internal host) are passed
# at run time so they are not written into the repository themselves:
#   HUB_EXTRA_FORBIDDEN='name|client|internal.example' scripts/check-clean.sh
set -eu
cd "$(dirname "$0")/.."

status=0
files=$(git ls-files --cached --others --exclude-standard)

# Files that should never be committed. .env.example is the one allowed .env file.
bad=$(printf '%s\n' "$files" | grep -E '(^|/)(\.env(\..*)?|\.DS_Store|id_rsa.*|id_ed25519.*|.*\.(pem|p12|pfx|key|keystore|jks|mobileprovision))$' \
  | grep -vx '.env.example' || true)
if [ -n "$bad" ]; then
  printf 'forbidden files:\n%s\n' "$bad" >&2
  status=1
fi

# Key-shaped strings.
keys='BEGIN [A-Z ]*PRIVATE KEY|sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[baprs]-[A-Za-z0-9-]{10,}'
# Home folders: only the made-up names the redaction tests use are allowed.
fixtures='^/(Users|home)/(me|alex|example|tester|someone|synthetic|realperson|\[REDACTED\])$'

printf '%s\n' "$files" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  if grep -IqE -e "$keys" -- "$f"; then
    echo "key-shaped string in $f" >&2
    echo fail
  fi
  homes=$(grep -IohE '/(Users|home)/[A-Za-z0-9._-]+' -- "$f" | grep -vE "$fixtures" | grep -vE '^/home/\.' | sort -u || true)
  if [ -n "$homes" ]; then
    echo "real-looking home path in $f: $(printf '%s ' "$homes" | tr '\n' ' ')" >&2
    echo fail
  fi
  if [ -n "${HUB_EXTRA_FORBIDDEN:-}" ] && grep -IqiE -e "$HUB_EXTRA_FORBIDDEN" -- "$f"; then
    echo "forbidden term in $f" >&2
    echo fail
  fi
done | grep -q fail && status=1

if [ "$status" -eq 0 ]; then echo "check-clean: ok"; fi
exit "$status"
