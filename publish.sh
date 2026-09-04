#!/usr/bin/env bash
# Publish the Mill Finance front end.
#
#   ./publish.sh check       run every safety check, publish nothing
#   ./publish.sh preview     a throwaway URL, nobody else has the link
#   ./publish.sh live        millfinance.fun
#
# The site is one self-contained HTML file. This script copies that one file
# into a clean folder and uploads only that folder, so nothing else in the
# repository can reach the internet by accident.
#
# What gets published is NOT simply your working copy: the MILLS array is
# filtered down to the addresses listed in publish.allow. No publish.allow, no
# live mills - the site is a roadmap. That is what lets you keep a rehearsal
# mill in web/index.html for local work without it ever reaching a visitor.
set -euo pipefail

PROJECT="${CF_PAGES_PROJECT:-millfinance}"
SRC="web/index.html"
OUT=".publish"
ALLOW="publish.allow"

die(){  printf '\033[31mstop\033[0m  %s\n' "$*" >&2; exit 1; }
ok(){   printf '\033[32m  ok\033[0m  %s\n' "$*"; }
warn(){ printf '\033[33mwarn\033[0m  %s\n' "$*"; }

MODE="${1:-preview}"
case "$MODE" in check|preview|live) ;; *) die "usage: ./publish.sh [check|preview|live]" ;; esac

[ -f "$SRC" ] || die "run this from the repository root - $SRC not found"

command -v node >/dev/null || die "node not found. See the runbook, 'Point millfinance.fun at Cloudflare'."
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 22 ] || die "wrangler needs Node 22 or newer, this shell has $(node -v). Run: nvm use 22"
ok "node $(node -v)"

# ---------------------------------------------------------------- source ----
TMPJS=$(mktemp /tmp/millcheck.XXXXXX.js)
trap 'rm -f "$TMPJS"' EXIT
sed -n '/<script>/,/<\/script>/p' "$SRC" | sed '/<\/\?script>/d' > "$TMPJS"
node --check "$TMPJS" 2>/dev/null || die "javascript does not parse - fix it before publishing"
ok "javascript parses"

! grep -q 'localhost\|127\.0\.0\.1' "$SRC" || die "$SRC still points at localhost"
ok "no localhost references"

RPC=$(grep -o 'rpc: *Q.get("rpc") *|| *"[^"]*"' "$SRC" | grep -o 'https\?://[^"]*' || true)
[ -n "$RPC" ] || die "could not find the RPC in $SRC"
ok "rpc $RPC"

CHAIN=$(grep -o 'chainId: *Number(Q.get("chain") *|| *[0-9]*' "$SRC" | grep -o '[0-9]*$' || true)
[ "$CHAIN" = "4663" ] || die "chainId is $CHAIN, expected 4663"
ok "chain 4663"

# ------------------------------------------------------------- assemble ----
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$SRC" "$OUT/index.html"

# The allow list. Blank lines and # comments ignored, case does not matter.
APPROVED=""
if [ -f "$ALLOW" ]; then
  APPROVED=$(grep -oiE '0x[0-9a-f]{40}' "$ALLOW" | tr 'A-F' 'a-f' | sort -u || true)
fi

# Rewrite MILLS in the BUILT copy - web/index.html is never touched. Entries are
# removed outright rather than filtered at runtime, so an address that is not
# approved does not appear in the published file at all.
FILTER_REPORT=$(APPROVED="$APPROVED" node -e '
const fs = require("fs");
const f = ".publish/index.html";
let s = fs.readFileSync(f, "utf8");

const decl = "const MILLS = [";
const i = s.indexOf(decl);
if (i < 0) { console.error("could not find the MILLS array"); process.exit(2); }

// Walk from the opening bracket to its match, collecting the top-level {...}
// entries. Brace depth, not a regular expression - an entry contains braces.
const open = i + decl.length - 1;
let depth = 0, close = -1;
for (let k = open; k < s.length; k++) {
  const c = s[k];
  if (c === "[" || c === "{") depth++;
  else if (c === "]" || c === "}") { depth--; if (depth === 0) { close = k; break; } }
}
if (close < 0) { console.error("could not find the end of the MILLS array"); process.exit(2); }

const body = s.slice(open + 1, close);
const entries = [];
let d = 0, from = -1;
for (let k = 0; k < body.length; k++) {
  if (body[k] === "{") { if (d === 0) from = k; d++; }
  else if (body[k] === "}") { d--; if (d === 0) entries.push(body.slice(from, k + 1)); }
}

const addrOf = e => (e.match(/address:"(0x[0-9a-fA-F]{40})"/) || [])[1] || "";
const approved = (process.env.APPROVED || "").split(/\s+/).filter(Boolean);
const keepE = entries.filter(e => approved.includes(addrOf(e).toLowerCase()));
const keep  = keepE.map(addrOf);
const drop  = entries.map(addrOf).filter(a => !keep.includes(a));

const rebuilt = keepE.length
  ? "\n  " + keepE.join(",\n  ") + ",\n"
  : "\n";
s = s.slice(0, open + 1) + rebuilt + s.slice(close);
fs.writeFileSync(f, s);
console.log(JSON.stringify({ keep, drop }));
')

KEEP=$(node -p "JSON.parse(process.argv[1]).keep.join(' ')" "$FILTER_REPORT")
DROP=$(node -p "JSON.parse(process.argv[1]).drop.join(' ')" "$FILTER_REPORT")

# the built file must still parse after that edit
sed -n '/<script>/,/<\/script>/p' "$OUT/index.html" | sed '/<\/\?script>/d' > "$TMPJS"
node --check "$TMPJS" 2>/dev/null || die "the filtered build does not parse - this is a bug in publish.sh, publish nothing"
ok "filtered build parses"

echo
if [ -n "$KEEP" ]; then
  echo "mills this build will show as LIVE:"
  for m in $KEEP; do echo "    $m"; done
else
  echo "no mill will show as live - the published page is a roadmap"
fi
if [ -n "$DROP" ]; then
  echo
  echo "mills in $SRC that will NOT be published (not in $ALLOW):"
  for m in $DROP; do echo "    $m"; done
fi
echo

# A missing allow file means "roadmap on purpose". An allow file that exists but
# misses a mill is far more likely to be a typo on launch day, so live stops.
if [ "$MODE" = "live" ] && [ -f "$ALLOW" ] && [ -n "$DROP" ]; then
  die "$ALLOW exists but does not cover every mill in $SRC.
      Either approve it -  echo <address> >> $ALLOW
      or take it out of MILLS in $SRC if it is a rehearsal mill."
fi

echo "every address the published build can hand a wallet:"
grep -oE '0x[0-9a-fA-F]{40}' "$OUT/index.html" | sort -u | sed 's/^/    /'
echo

SUM=$(sha256sum "$OUT/index.html" | cut -c1-16)
ok "built $OUT ($(wc -c < "$OUT/index.html") bytes, sha256 $SUM...)"

if [ "$MODE" = "check" ]; then ok "checks only, nothing published"; exit 0; fi

# Sent with every response by Cloudflare Pages. The page loads nothing from
# anywhere except the RPC, so say so - a script injected into this page could
# otherwise ship a swapped address to an attacker's server.
cat > "$OUT/_headers" <<HEADERS
/*
  Cache-Control: public, max-age=0, must-revalidate
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer
  Permissions-Policy: geolocation=(), microphone=(), camera=(), payment=()
  Content-Security-Policy: default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src ${RPC}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
HEADERS

# -------------------------------------------------------------- publish ----
case "$MODE" in
  preview)
    npx wrangler@latest pages deploy "$OUT" --project-name "$PROJECT" --branch preview
    echo
    ok "preview is up. The URL above is unlisted; millfinance.fun is unchanged."
    ;;
  live)
    echo "This publishes to millfinance.fun, where strangers will sign transactions."
    printf "Type the sha256 prefix shown above to confirm: "
    read -r typed
    [ "$typed" = "$SUM" ] || die "did not match - nothing published"
    npx wrangler@latest pages deploy "$OUT" --project-name "$PROJECT" --branch main
    echo
    ok "live. Open https://millfinance.fun in a private window and check the addresses."
    ;;
esac
