#!/usr/bin/env bash
# Differential equivalence for the pretool-guard security control.
#
# Runs the SAME payloads through a reference revision of the guard and the
# working-tree one, and compares exit codes. When a security control is
# rewritten for speed, a suite that only passes on the new version is not
# evidence of equivalence — the old version has to agree, case by case.
#
# Usage:  tests/guard-equivalence.sh [ref]        (default ref: HEAD)
#
# Exits non-zero on any divergence, so it can gate a rewrite.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REF="${1:-HEAD}"
OLD="$(mktemp)"
if ! git show "$REF:scripts/pretool-guard.sh" >"$OLD" 2>/dev/null; then
  echo "cannot read scripts/pretool-guard.sh at $REF" >&2
  rm -f "$OLD"
  exit 1
fi
NEW=scripts/pretool-guard.sh

# Every deny branch, plus the allow cases that guard against false positives.
# Built as name<TAB>command so commands may contain spaces and quotes.
cases=$(cat <<'CASES'
force-push	git push --force origin main
force-push-f	git push -f origin main
force-push-refspec	git push origin +HEAD:main
force-push-C	git -C /repo push --force
allow-force-with-lease	git push --force-with-lease origin main
allow-normal-push	git push origin main
bare-gh-merge	gh pr merge 7
gh-merge-R-before	gh -R o/r pr merge 7
gh-merge-R-between	gh pr -R o/r merge 7
allow-gated-merge	gh pr merge 7 --match-head-commit abc123
allow-merge-filename	cat posttool-gh-pr-merge.bats
allow-create-body-merge	gh pr create --body "ready to merge"
repo-delete	gh repo delete o/r
repo-visibility	gh repo edit o/r --visibility public
credentials-json	cat ~/.credentials.json
ssh-key-read	cat ~/.ssh/id_rsa
ssh-key-win	type C:\Users\me\.ssh\id_ed25519
allow-ssh-use	ssh -i ~/.ssh/id_rsa host
gate-state-rm	rm ~/pers/gate/state/foo
gate-state-win	Remove-Item C:\Users\me\pers\gate\state\x
gate-state-dev-home	rm ~/dev/gate/state/foo
gate-keys-rm	rm ~/dev/gate/keys/signing.key
gate-keys-win	Move-Item C:\Users\me\dev\gate\keys\x y
allow-gate-internal-state	rm gate/internal/state/foo.go
allow-aggregate-state	rm aggregate/state/foo
allow-delegate-keys	rm delegate/keys/foo
allow-gate-state-backup	rm gate/state_backup/foo
allow-gate-judge-why	gate judge -run run_abc -grant grt_x -why "score normalization applied" -state ~/dev/gate/state
gate-keys-scp	scp ~/dev/gate/keys/signing.key host:/tmp/key
gate-keys-rsync	rsync -a ~/dev/gate/keys/ host:/tmp/keys/
gate-keys-copy-item	Copy-Item C:\Users\me\dev\gate\keys\signing.key C:\tmp\k
gate-keys-copy-item-lower	copy-item C:\Users\me\dev\gate\keys\signing.key C:\tmp\k
gate-keys-rcp	rcp ~/dev/gate/keys/signing.key host:/tmp/k
gate-keys-pscp	pscp C:\Users\me\dev\gate\keys\signing.key host:/tmp/k
gate-keys-srm	srm ~/dev/gate/keys/signing.key
gate-state-rmdir	rmdir ~/dev/gate/state
custody-grant	custody grant -key k -actions read -ttl 8h
custody-keys	custody keys set -name tracker
custody-exe	./custody.exe grant -key k
custody-quoted	"custody.exe" Grant -key k
custody-piped	echo x | custody grant -key k
custody-chained	cd /tmp && custody grant -key k
allow-custody-log	custody log
allow-custody-prose	git commit -m "document custody grant"
allow-custody-search	rg "custody keys" docs
custody-state	rm ~/.custody/log
custody-state-win	Remove-Item C:\Users\me\.custody\log
keys-read	cat ~/.keys
keys-upper	cat ~/.KEYS
allow-keystore	cat ~/.keystore
allow-keys-prose	git commit -m "remove .keys"
allow-plain	echo hello
allow-ls	ls -la /tmp
CASES
)

pass=0; fail=0
printf '%-26s %-6s %-6s %s\n' "case" "old" "new" "verdict"
printf '%-26s %-6s %-6s %s\n' "----" "---" "---" "-------"

while IFS=$'\t' read -r name cmd; do
  [ -n "$name" ] || continue
  payload=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}')

  # GUARD_KEYS_DENY toggles the .keys rule; exercise it on for those cases.
  keysenv=0
  case "$name" in keys-*|allow-keystore|allow-keys-prose) keysenv=1 ;; esac

  GUARD_KEYS_DENY=$keysenv bash "$OLD" <<<"$payload" >/dev/null 2>&1; o=$?
  GUARD_KEYS_DENY=$keysenv bash "$NEW" <<<"$payload" >/dev/null 2>&1; n=$?

  if [ "$o" -eq "$n" ]; then
    printf '%-26s %-6s %-6s same\n' "$name" "$o" "$n"
    pass=$((pass+1))
  else
    printf '%-26s %-6s %-6s *** DIVERGED ***\n' "$name" "$o" "$n"
    fail=$((fail+1))
  fi
done <<<"$cases"

echo
echo "identical: $pass    diverged: $fail"
rm -f "$OLD"
[ "$fail" -eq 0 ]
