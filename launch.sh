#!/usr/bin/env bash
# ===========================================================================
# Mill launch runner.
#
#   ./launch.sh localstack      bare anvil + the whole stack, for a dry run
#   ./launch.sh preflight       everything that must be true before you start
#   ./launch.sh phase2          deploy the mMILL vault
#   ./launch.sh phase3          mine and deploy the hook
#   ./launch.sh phase3b         configure the pool on the hook   [ONCE ONLY]
#   ./launch.sh phase4          initialise the pool at backing   [IRREVERSIBLE]
#   ./launch.sh phase6          deploy the LP staking vault
#   ./launch.sh webconfig       write the mill into the app's config
#   ./launch.sh verify          read the whole system back and check it
#   ./launch.sh report          the peg / band report
#
# Each phase stops before broadcasting and asks. Nothing here holds a key:
# signing is always `--account deployer`, so every broadcast prompts for the
# keystore password.
# ===========================================================================
set -euo pipefail

cd "$(dirname "$0")"

R="\033[0;31m"; G="\033[0;32m"; Y="\033[0;33m"; B="\033[1m"; N="\033[0m"
say()  { printf "${B}%s${N}\n" "$*"; }
ok()   { printf "  ${G}ok${N}    %s\n" "$*"; }
warn() { printf "  ${Y}warn${N}  %s\n" "$*"; }
die()  { printf "  ${R}stop${N}  %s\n" "$*"; exit 1; }

# Loaded when present. `localstack` deploys a self-contained stack on anvil and
# needs none of it, so only the phases that talk to a real chain insist on it.
[ -f launch.env ] && { set -a; . ./launch.env; set +a; }

with_env() { [ -f launch.env ] || die "launch.env not found. cp launch.env.example launch.env"; }
need() { with_env; [ -n "${!1:-}" ] && [ "${!1}" != "0x" ] || die "$1 is not set in launch.env"; }
code() { local n; n=$(cast code "$1" --rpc-url "$RH_RPC" 2>/dev/null | wc -c); [ "$n" -gt 4 ]; }

confirm() {
  printf "\n${Y}%s${N}\n" "$1"
  read -r -p "  type the word GO to continue: " a
  [ "$a" = "GO" ] || die "aborted"
}

# ---------------------------------------------------------------------------
localstack() {
  say "local stack"
  # Deliberately NOT a fork. LocalStack deploys PoolManager, Permit2 and the
  # PositionManager itself, so it needs a bare anvil — and a fork of Robinhood
  # Chain keeps chain id 4663, which the script's anvil-only guard rejects.
  if cast chain-id --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1; then
    ok "anvil already listening on 8545"
  else
    anvil --port 8545 --chain-id 31337 >/tmp/anvil.log 2>&1 &
    printf "  starting anvil"
    for _ in $(seq 1 30); do
      cast chain-id --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1 && break
      printf "."; sleep 1
    done
    printf "\n"
    cast chain-id --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1 || die "anvil did not come up; see /tmp/anvil.log"
    ok "anvil up"
  fi

  local id; id=$(cast chain-id --rpc-url http://127.0.0.1:8545)
  [ "$id" = "31337" ] || die "local node reports chain $id; LocalStack requires 31337 (do not use --fork-url)"

  forge script script/LocalStack.s.sol:LocalStack --rpc-url http://127.0.0.1:8545 --broadcast
  say "addresses above go into the app's CFG overrides, e.g. ?rpc=http://127.0.0.1:8545&mill=0x..."
}

preflight() {
  say "preflight"
  for v in RH_RPC DEPLOYER OWNER HOOK_OWNER FEE_RECIPIENT RESCUER QUOTE; do need "$v"; done

  local id; id=$(cast chain-id --rpc-url "$RH_RPC")
  [ "$id" = "$CHAIN_ID" ] || die "rpc reports chain $id, expected $CHAIN_ID"
  ok "chain $id reachable"

  local bal; bal=$(cast balance "$DEPLOYER" --rpc-url "$RH_RPC")
  [ "$bal" != "0" ] || die "deployer $DEPLOYER has no gas"
  ok "deployer funded: $(cast from-wei "$bal") ETH"

  cast wallet address --account deployer >/dev/null 2>&1 \
    && ok "keystore 'deployer' present" \
    || warn "could not read keystore 'deployer' without a password prompt"

  code "$QUOTE"        || die "QUOTE $QUOTE has no code on this chain"
  code "$POOL_MANAGER" || die "POOL_MANAGER has no code"
  code "$POSM"         || die "POSM has no code"
  ok "quote token and v4 infrastructure present"

  local qs qd
  qs=$(cast call "$QUOTE" "symbol()(string)" --rpc-url "$RH_RPC")
  qd=$(cast call "$QUOTE" "decimals()(uint8)" --rpc-url "$RH_RPC")
  ok "quote is $qs with $qd decimals"

  [ "${MILL_TOKEN,,}" != "${QUOTE,,}" ] || die "QUOTE must not be the MILL token itself"

  for v in WRAP_FEE_BPS UNWRAP_FEE_BPS MIN_BURN_BPS BURN_BPS LP_BPS SELL_BPS; do
    [ "${!v}" -le 10000 ] || die "$v is above 10000"
  done
  [ "$WRAP_FEE_BPS"   -le 100 ] || die "WRAP_FEE_BPS max is 100"
  [ "$UNWRAP_FEE_BPS" -le 300 ] || die "UNWRAP_FEE_BPS max is 300"
  [ "$SELL_BPS"       -le 500 ] || die "SELL_BPS max is 500"
  [ "$BURN_BPS" -ge "$MIN_BURN_BPS" ] || die "BURN_BPS is below MIN_BURN_BPS"
  [ $((BURN_BPS + LP_BPS)) -le 10000 ] || die "BURN_BPS + LP_BPS exceeds 10000"
  ok "fee parameters within their permanent limits"

  [ "${HOOK_VAULT,,}" != "${MILL,,}" ] || die "HOOK_VAULT must never be the Mill"
  ok "hook vault is not the Mill"

  say "these are immutable once deployed:"
  printf "  wrap %s bps · unwrap %s bps · burn floor %s bps\n" \
    "$WRAP_FEE_BPS" "$UNWRAP_FEE_BPS" "$MIN_BURN_BPS"
  printf "  owner %s\n" "$OWNER"
  forge test --summary >/dev/null && ok "test suite green" || die "tests are failing"
}

# ---------------------------------------------------------------------------
phase2() {
  need MILL_TOKEN
  say "phase 2 — deploy the mMILL vault over $MILL_TOKEN"
  local seedargs=""
  [ "$SEED_AMOUNT" != "0" ] && { need SEED_RECIPIENT; seedargs="SEED_AMOUNT=$SEED_AMOUNT SEED_RECIPIENT=$SEED_RECIPIENT"; }
  confirm "wrap/unwrap fees and the burn floor can never be changed after this."
  env ASSET="$MILL_TOKEN" MILL_NAME="$MILL_NAME" MILL_SYMBOL="$MILL_SYMBOL" \
      FEE_RECIPIENT="$FEE_RECIPIENT" OWNER="$OWNER" LP_RECIPIENT="$FEE_RECIPIENT" \
      WRAP_FEE_BPS="$WRAP_FEE_BPS" UNWRAP_FEE_BPS="$UNWRAP_FEE_BPS" \
      MIN_BURN_BPS="$MIN_BURN_BPS" BURN_BPS="$BURN_BPS" LP_BPS="$LP_BPS" $seedargs \
    forge script script/Deploy.s.sol:Deploy \
      --rpc-url "$RH_RPC" --account deployer --sender "$DEPLOYER" --broadcast -vvvv
  say "put the deployed address in launch.env as MILL="
}

phase3() {
  say "phase 3 — mine and deploy the hook (owner: $HOOK_OWNER)"
  HOOK_OWNER="$HOOK_OWNER" forge script script/DeployHook.s.sol:DeployHook \
    --rpc-url "$RH_RPC" --account deployer --sender "$DEPLOYER" --broadcast -vvvv
  say "put the deployed address in launch.env as HOOK="
}

phase3b() {
  need MILL; need HOOK; need HOOK_VAULT
  code "$HOOK" || die "HOOK has no code"
  say "phase 3b - configure the pool on the hook"
  printf "  sell side %s bps, buy side 0, fees to %s\n" "$SELL_BPS" "$HOOK_VAULT"

  # v4 sorts currencies ascending, so which DIRECTION sells the milled token
  # depends on how the Mill's address compares to the quote's. Work it out here
  # rather than leaving it to whoever is reading the log.
  local m q c0 c1 zbps obps
  m=$(printf '%s' "$MILL"  | tr 'A-Z' 'a-z')
  q=$(printf '%s' "$QUOTE" | tr 'A-Z' 'a-z')
  if [[ "$m" < "$q" ]]; then c0=$MILL; c1=$QUOTE; zbps=$SELL_BPS; obps=0
  else                       c0=$QUOTE; c1=$MILL; zbps=0; obps=$SELL_BPS; fi
  local key="($c0,$c1,$LP_FEE,$TICK_SPACING,$HOOK)"

  # configurePool is onlyOwner on the hook. If HOOK_OWNER is a multisig - as it
  # should be - the deployer cannot make this call, and broadcasting it only
  # produces an Unauthorized revert. Hand over the calldata instead.
  local howner dep
  howner=$(cast call "$HOOK" 'owner()(address)' --rpc-url "$RH_RPC")
  dep=$(cast wallet address --account deployer 2>/dev/null || echo "$DEPLOYER")
  if [ "${howner,,}" != "${dep,,}" ]; then
    warn "the hook is owned by $howner, not the deployer"
    say "send this to $HOOK, value 0, from $howner:"
    printf "\n"
    cast calldata "configurePool((address,address,uint24,int24,address),address,uint16,uint16)" \
      "$key" "$HOOK_VAULT" "$zbps" "$obps"
    printf "\n"
    say "then confirm:"
    printf "  cast call %s \"getEffectiveRates((address,address,uint24,int24,address))(uint16,uint16)\" \"%s\" --rpc-url \$RH_RPC\n" "$HOOK" "$key"
    return 0
  fi

  confirm "configurePool is ONCE ONLY for this pool. Rates can be changed later, but only with a 5 minute delay."
  env HOOK="$HOOK" MILL="$MILL" QUOTE="$QUOTE" VAULT="$HOOK_VAULT" SELL_BPS="$SELL_BPS" \
      LP_FEE="$LP_FEE" TICK_SPACING="$TICK_SPACING" \
    forge script script/DeployHook.s.sol:ConfigurePool \
      --rpc-url "$RH_RPC" --account deployer --sender "$DEPLOYER" --broadcast -vvvv
  warn "if this reverted Unauthorized, the hook owner is the multisig — send it from there"
}

phase4() {
  need MILL; need HOOK
  say "phase 4 — initialise the pool AT BACKING"
  local underlying; underlying=$(cast call "$MILL" "asset()(address)" --rpc-url "$RH_RPC")
  local r;      r=$(cast call "$MILL" "ratio()(uint256)" --rpc-url "$RH_RPC" | cut -d' ' -f1)
  local parked; parked=$(cast call "$MILL" "balanceOf(address)(uint256)" "$MILL" --rpc-url "$RH_RPC" | cut -d' ' -f1)
  printf "  underlying     %s\n  quote          %s\n" "$underlying" "$QUOTE"
  printf "  ratio now      %s\n  parked fees    %s  (the script settles these first)\n" "$r" "$parked"

  # ratio() is denominated in the UNDERLYING. When the pool is quoted in
  # anything else the pool price is ratio x the market price of the underlying,
  # and there is no safe default for that second number.
  # The script settles fees before reading the ratio, so the ratio printed above
  # is NOT the one the pool opens at. Work out what it becomes, or the preview
  # understates the opening price by the whole pending burn.
  local ts bb settled
  ts=$(cast call "$MILL" 'totalSupply()(uint256)' --rpc-url "$RH_RPC" | cut -d' ' -f1)
  bb=$(cast call "$MILL" 'burnBps()(uint16)'      --rpc-url "$RH_RPC" | cut -d' ' -f1)
  settled=$(python3 -c "
r, ts, p, bb = int($r), int($ts), int($parked), int($bb)
burn = p * bb // 10000
off = 1000
print(r * (ts + off) // (ts - burn + off))
" 2>/dev/null || echo "$r")
  [ "$settled" != "$r" ] && printf "  ratio after settle %s  (the burn lifts it)\n" "$settled"

  local qpa="${QUOTE_PER_ASSET:-}"
  if [ "${QUOTE,,}" = "${underlying,,}" ]; then
    qpa=1000000000000000000
    ok "quote is the underlying, so the ratio alone sets the price"
  else
    [ -n "$qpa" ] && [ "$qpa" != "0" ] \
      || die "QUOTE is not the underlying - set QUOTE_PER_ASSET in launch.env (1e18-scaled price of one whole underlying in whole quote)"
    printf "  quote/underlying %s\n" "$qpa"
    local implied; implied=$(python3 -c "print(f'{int($settled)*int($qpa)/10**36:.18f}')" 2>/dev/null || echo "")
    [ -n "$implied" ] || die "could not compute the opening price - refusing to continue blind on an irreversible step"
    printf "  ${Y}one whole milled token opens at %s of the quote${N}\n" "$implied"
    warn "check that against the live market before you continue"
  fi

  confirm "A pool can only be initialised once, and its opening price is where the first trade happens."
  env MILL="$MILL" QUOTE="$QUOTE" HOOK="$HOOK" LP_FEE="$LP_FEE" TICK_SPACING="$TICK_SPACING" \
      QUOTE_PER_ASSET="$qpa" \
    forge script script/Rehearsal.s.sol:InitPool \
      --rpc-url "$RH_RPC" --account deployer --sender "$DEPLOYER" --broadcast -vvvv
  say "record the block number in launch.env as POOL_BLOCK="
}

phase6() {
  need MILL; need HOOK; need RESCUER; need LENS
  say "phase 6 — deploy the LP staking vault"
  env MILL="$MILL" QUOTE="$QUOTE" HOOK="$HOOK" LP_FEE="$LP_FEE" TICK_SPACING="$TICK_SPACING" \
      RESCUER="$RESCUER" LENS="$LENS" \
    forge script script/DeployLPStaking.s.sol:DeployLPStaking \
      --rpc-url "$RH_RPC" --account deployer --sender "$DEPLOYER" --broadcast -vvvv
  say "put the address in launch.env as LP_STAKING=, then have $OWNER call:"
  printf "  cast calldata \"setLpRecipient(address)\" <LP_STAKING>\n"
}

# ---------------------------------------------------------------------------
# Rewrites the MILLS array in the app so it stops depending on a URL full of
# query parameters. Run it after phase 6, or after phase 4 if the staking vault
# does not exist yet.
webconfig() {
  need MILL; need QUOTE; need HOOK
  [ -n "${POOL_BLOCK:-}" ] || die "POOL_BLOCK is not set - record it after phase 4"
  [ -f web/index.html ] || die "web/index.html not found"

  local since
  since=$(cast block "$POOL_BLOCK" --field timestamp --rpc-url "$RH_RPC" | cut -d' ' -f1)
  ok "pool block $POOL_BLOCK is unix $since"

  python3 - "$MILL" "$QUOTE" "$HOOK" "$POOL_BLOCK" "$since" "${LP_STAKING:-}" \
           "${LP_FEE:-3000}" "${TICK_SPACING:-60}" <<'PY'
import sys, pathlib, re
mill, quote, hook, blk, since, staking, fee, spacing = sys.argv[1:9]
entry  = '  { address:"%s", since:%s, price:null,\n' % (mill, since)
if staking and staking not in ("0x", ""):
    entry += '    staking:"%s",\n' % staking
entry += ('    pool:{ quote:"%s", fee:%s, tickSpacing:%s,\n'
          '           hooks:"%s", fromBlock:%s } },\n') % (quote, fee, spacing, hook, blk)

p = pathlib.Path("web/index.html"); s = p.read_text()
new = "const MILLS = [\n" + entry + "];"
out, n = re.subn(r"const MILLS = \[.*?\n\];", new, s, count=1, flags=re.S)
if not n:
    print("MILLS array not found - is this the right file?"); raise SystemExit(1)
p.write_text(out)
print("web/index.html: MILLS now lists one mill")
PY

  say "serve it and open http://localhost:8010/ with no query string:"
  printf "  cd web && python3 -m http.server 8010\n"
}

report() {
  need MILL; need HOOK
  env MILL="$MILL" QUOTE="$QUOTE" HOOK="$HOOK" LP_FEE="$LP_FEE" TICK_SPACING="$TICK_SPACING" \
    forge script script/Rehearsal.s.sol:Report --rpc-url "$RH_RPC"
}

# ---------------------------------------------------------------------------
verify() {
  need MILL
  say "vault"
  local get; get() { cast call "$MILL" "$1" --rpc-url "$RH_RPC"; }
  printf "  asset          %s\n" "$(cast call "$MILL" 'asset()(address)' --rpc-url "$RH_RPC")"
  printf "  owner          %s\n" "$(cast call "$MILL" 'owner()(address)' --rpc-url "$RH_RPC")"
  printf "  feeRecipient   %s\n" "$(cast call "$MILL" 'feeRecipient()(address)' --rpc-url "$RH_RPC")"
  printf "  lpRecipient    %s\n" "$(cast call "$MILL" 'lpRecipient()(address)' --rpc-url "$RH_RPC")"
  printf "  wrap/unwrap    %s / %s bps\n" \
    "$(cast call "$MILL" 'wrapFeeBps()(uint16)' --rpc-url "$RH_RPC")" \
    "$(cast call "$MILL" 'unwrapFeeBps()(uint16)' --rpc-url "$RH_RPC")"
  printf "  burn floor     %s bps\n"  "$(cast call "$MILL" 'minBurnBps()(uint16)' --rpc-url "$RH_RPC")"
  printf "  split          burn %s / lp %s bps\n" \
    "$(cast call "$MILL" 'burnBps()(uint16)' --rpc-url "$RH_RPC")" \
    "$(cast call "$MILL" 'lpBps()(uint16)' --rpc-url "$RH_RPC")"
  printf "  ratio          %s\n" "$(cast call "$MILL" 'ratio()(uint256)' --rpc-url "$RH_RPC")"
  printf "  parked fees    %s\n" "$(cast call "$MILL" 'balanceOf(address)(uint256)' "$MILL" --rpc-url "$RH_RPC")"

  local o; o=$(cast call "$MILL" 'owner()(address)' --rpc-url "$RH_RPC")
  [ "${o,,}" = "${OWNER,,}" ] && ok "owner matches launch.env" || warn "owner is $o, expected $OWNER"

  if [ -n "${HOOK:-}" ] && [ "$HOOK" != "0x" ]; then
    say "hook"
    printf "  owner          %s\n" "$(cast call "$HOOK" 'owner()(address)' --rpc-url "$RH_RPC")"
    printf "  operator       %s\n" "$(cast call "$HOOK" 'operator()(address)' --rpc-url "$RH_RPC")"
    printf "  paused         %s\n" "$(cast call "$HOOK" 'paused()(bool)' --rpc-url "$RH_RPC")"
    printf "  flags          %s (must be 68)\n" "$((16#$(printf '%s' "${HOOK: -4}") & 0x3FFF))"
  fi

  if [ -n "${LP_STAKING:-}" ] && [ "$LP_STAKING" != "0x" ]; then
    say "staking vault"
    printf "  reward         %s\n" "$(cast call "$LP_STAKING" 'reward()(address)' --rpc-url "$RH_RPC")"
    printf "  rescuer        %s\n" "$(cast call "$LP_STAKING" 'rescuer()(address)' --rpc-url "$RH_RPC")"
    printf "  warmup         %s s\n" "$(cast call "$LP_STAKING" 'WARMUP()(uint256)' --rpc-url "$RH_RPC")"
    printf "  totalWeight    %s\n" "$(cast call "$LP_STAKING" 'totalWeight()(uint256)' --rpc-url "$RH_RPC")"
    printf "  warming        %s\n" "$(cast call "$LP_STAKING" 'warming()(uint256)' --rpc-url "$RH_RPC")"
    printf "  unallocated    %s\n" "$(cast call "$LP_STAKING" 'unallocated()(uint256)' --rpc-url "$RH_RPC")"
    local lp; lp=$(cast call "$MILL" 'lpRecipient()(address)' --rpc-url "$RH_RPC")
    [ "${lp,,}" = "${LP_STAKING,,}" ] && ok "the Mill pays its LP leg to the vault" \
      || warn "lpRecipient is $lp, not the vault — run setLpRecipient from $OWNER"
  fi
}

case "${1:-}" in
  localstack|preflight|phase2|phase3|phase3b|phase4|phase6|webconfig|verify|report) "$1" ;;
  *) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
