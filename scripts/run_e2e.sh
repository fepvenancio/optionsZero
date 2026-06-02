#!/usr/bin/env bash
# =============================================================================
# run_e2e.sh — OptionZero Full E2E Live Simulation Orchestrator
# =============================================================================
#
# Starts Anvil, deploys the full OptionZero stack, verifies ABI selectors,
# builds the Rust daemon, and launches it against the local node.
#
# Usage:
#   ./scripts/run_e2e.sh
#
# In a second terminal, run the three simulation phases:
#   PHASE=1 ./scripts/simulate.sh    # genesis deposit (daemon stays quiet)
#   PHASE=2 ./scripts/simulate.sh    # open hedge     (daemon stays quiet)
#   PHASE=3 ./scripts/simulate.sh    # market crash   (daemon prints intent JSON)
#
# Requirements:
#   - foundry  (forge, cast, anvil)   https://getfoundry.sh
#   - cargo / rustc (Rust toolchain)  https://rustup.rs
# =============================================================================

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$REPO_ROOT/contracts"
DAEMON_DIR="$REPO_ROOT/daemon"
ANVIL_PID_FILE="/tmp/optionzero_anvil.pid"
DEPLOY_OUTPUT="/tmp/optionzero_deploy.env"

ANVIL_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_RPC="http://127.0.0.1:8545"

# Explicit binary paths (avoids PATH collision with other tools named 'forge').
# Override via FORGE_BIN / CAST_BIN / ANVIL_BIN env vars if needed.
FOUNDRY_HOME="${FOUNDRY_HOME:-$HOME/.foundry/bin}"
FORGE="${FORGE_BIN:-$FOUNDRY_HOME/forge}"
CAST="${CAST_BIN:-$FOUNDRY_HOME/cast}"
ANVIL="${ANVIL_BIN:-$FOUNDRY_HOME/anvil}"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[E2E]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ── Step 0: Sanity checks ─────────────────────────────────────────────────────
info "Checking dependencies..."
command -v "$FORGE" >/dev/null 2>&1 || die "forge not found at $FORGE"
command -v "$CAST"  >/dev/null 2>&1 || die "cast not found at $CAST"
command -v "$ANVIL" >/dev/null 2>&1 || die "anvil not found at $ANVIL"
command -v cargo    >/dev/null 2>&1 || die "cargo not found -- install Rust: https://rustup.rs"
info "All dependencies present."

# ── Step 1: Kill any existing Anvil on port 8545 ─────────────────────────────
info "Stopping any existing Anvil instance on :8545..."
if lsof -ti:8545 >/dev/null 2>&1; then
    lsof -ti:8545 | xargs kill -9 2>/dev/null || true
    sleep 1
fi

# ── Step 2: Start Anvil ───────────────────────────────────────────────────────
info "Starting Anvil (block-time=2s, chain-id=31337)..."
"$ANVIL" \
    --block-time 2 \
    --chain-id   31337 \
    --port       8545 \
    --silent \
    > /tmp/optionzero_anvil.log 2>&1 &
ANVIL_PID=$!
echo "$ANVIL_PID" > "$ANVIL_PID_FILE"

# Wait for Anvil to be ready (up to 10 seconds).
for i in $(seq 1 20); do
    if "$CAST" block-number --rpc-url "$ANVIL_RPC" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
"$CAST" block-number --rpc-url "$ANVIL_RPC" >/dev/null 2>&1 \
    || die "Anvil did not start in time. Check /tmp/optionzero_anvil.log"
info "Anvil started (PID=$ANVIL_PID, $($CAST block-number --rpc-url $ANVIL_RPC) blocks)."

# Ensure Anvil is killed on script exit.
trap 'info "Shutting down Anvil (PID=$ANVIL_PID)..."; kill $ANVIL_PID 2>/dev/null; true' EXIT

# ── Step 3: Compile contracts ─────────────────────────────────────────────────
info "Compiling contracts..."
cd "$CONTRACTS_DIR"
"$FORGE" build --quiet
info "Contracts compiled."

# ── Step 4: Deploy the full stack ────────────────────────────────────────────
info "Deploying OptionZero to Anvil..."
DEPLOY_LOG=$(
    PRIVATE_KEY="$ANVIL_KEY" \
    "$FORGE" script script/Deploy.s.sol \
        --rpc-url    "$ANVIL_RPC" \
        --broadcast  \
        --private-key "$ANVIL_KEY" \
        2>&1
)

echo "$DEPLOY_LOG" | grep -E "^[A-Z_]+=0x" > "$DEPLOY_OUTPUT" || true

# Parse deployed addresses directly from forge console output.
parse_addr() {
    echo "$DEPLOY_LOG" | grep -oE "${1}=0x[0-9a-fA-F]{40}" | head -1 | cut -d= -f2
}

export WSTETH_ADDRESS=$(parse_addr "WSTETH_ADDRESS")
export VAULT_ADDRESS=$(parse_addr "VAULT_ADDRESS")
export ADAPTER_ADDRESS=$(parse_addr "ADAPTER_ADDRESS")
export TRANCHER_ADDRESS=$(parse_addr "TRANCHER_ADDRESS")
export PTOKEN_ADDRESS=$(parse_addr "PTOKEN_ADDRESS")
export NTOKEN_ADDRESS=$(parse_addr "NTOKEN_ADDRESS")

[[ -n "$VAULT_ADDRESS"   ]] || die "VAULT_ADDRESS not found in deploy output"
[[ -n "$ADAPTER_ADDRESS" ]] || die "ADAPTER_ADDRESS not found in deploy output"
[[ -n "$WSTETH_ADDRESS"  ]] || die "WSTETH_ADDRESS not found in deploy output"

info "Deployed contracts:"
info "  WSTETH_ADDRESS   = $WSTETH_ADDRESS"
info "  VAULT_ADDRESS    = $VAULT_ADDRESS"
info "  ADAPTER_ADDRESS  = $ADAPTER_ADDRESS"
info "  TRANCHER_ADDRESS = $TRANCHER_ADDRESS"
info "  PTOKEN_ADDRESS   = $PTOKEN_ADDRESS"
info "  NTOKEN_ADDRESS   = $NTOKEN_ADDRESS"

# Save to file for simulate.sh to source.
cat > "$DEPLOY_OUTPUT" <<EOF
export WSTETH_ADDRESS=$WSTETH_ADDRESS
export VAULT_ADDRESS=$VAULT_ADDRESS
export ADAPTER_ADDRESS=$ADAPTER_ADDRESS
export TRANCHER_ADDRESS=$TRANCHER_ADDRESS
export PTOKEN_ADDRESS=$PTOKEN_ADDRESS
export NTOKEN_ADDRESS=$NTOKEN_ADDRESS
export ANVIL_KEY=$ANVIL_KEY
export ETH_RPC_URL=$ANVIL_RPC
EOF
info "Addresses saved to $DEPLOY_OUTPUT"

# ── Step 5: Verify ABI selectors used by the daemon ─────────────────────────
info "Verifying ABI selectors (cast sig)..."

SEL_DELTA=$("$CAST" sig "currentDelta()")
SEL_NOTIONAL=$("$CAST" sig "totalHedgedNotional()")
SEL_ASSETS=$("$CAST" sig "totalAssets()")

EXPECTED_DELTA="0x3b14422b"
EXPECTED_NOTIONAL="0x0d4c2e24"
EXPECTED_ASSETS="0x01e1d114"

echo "  currentDelta()         = $SEL_DELTA  (expected $EXPECTED_DELTA)"
echo "  totalHedgedNotional()  = $SEL_NOTIONAL (expected $EXPECTED_NOTIONAL)"
echo "  totalAssets()          = $SEL_ASSETS (expected $EXPECTED_ASSETS)"

[[ "$SEL_DELTA"    == "$EXPECTED_DELTA"    ]] || warn "currentDelta() selector mismatch! Update rpc.rs SEL_CURRENT_DELTA"
[[ "$SEL_NOTIONAL" == "$EXPECTED_NOTIONAL" ]] || warn "totalHedgedNotional() selector mismatch! Update rpc.rs SEL_TOTAL_HEDGED_NOTIONAL"
[[ "$SEL_ASSETS"   == "$EXPECTED_ASSETS"   ]] || warn "totalAssets() selector mismatch! Update rpc.rs SEL_TOTAL_ASSETS"

# Smoke-test the adapter's currentDelta() eth_call.
info "Smoke-testing eth_call currentDelta()..."
RAW=$("$CAST" call "$ADAPTER_ADDRESS" "currentDelta()(int256)" --rpc-url "$ANVIL_RPC")
info "  currentDelta() raw = $RAW (expect -950000000000000000 for DITM default)"

# ── Step 6: Build the daemon ──────────────────────────────────────────────────
info "Building Rust daemon..."
cd "$DAEMON_DIR"
cargo build --release --quiet
DAEMON_BIN="$DAEMON_DIR/target/release/optionszero-daemon"
[[ -f "$DAEMON_BIN" ]] || die "Daemon binary not found at $DAEMON_BIN"
info "Daemon built: $DAEMON_BIN"

# ── Step 7: Print simulation guide ───────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  OptionZero E2E Simulation -- READY${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Anvil      : $ANVIL_RPC (PID=$ANVIL_PID, block-time=2s)"
echo "  Vault      : $VAULT_ADDRESS"
echo "  Adapter    : $ADAPTER_ADDRESS"
echo ""
echo "  In a SECOND terminal, run the simulation phases:"
echo ""
echo "    source $DEPLOY_OUTPUT"
echo ""
echo "    # Phase 1: Genesis deposit (daemon stays quiet)"
echo "    PHASE=1 forge script contracts/script/Simulate.s.sol \\"
echo "      --rpc-url $ANVIL_RPC --broadcast --private-key \$ANVIL_KEY"
echo ""
echo "    # Phase 2: Open DITM hedge (daemon stays quiet)"
echo "    PHASE=2 forge script contracts/script/Simulate.s.sol \\"
echo "      --rpc-url $ANVIL_RPC --broadcast --private-key \$ANVIL_KEY"
echo ""
echo "    # Phase 3: Market crash -> daemon prints intent JSON"
echo "    PHASE=3 forge script contracts/script/Simulate.s.sol \\"
echo "      --rpc-url $ANVIL_RPC --broadcast --private-key \$ANVIL_KEY"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── Step 8: Launch the daemon ─────────────────────────────────────────────────
info "Launching daemon (polling every 5s, threshold=0.05)..."
info "Watching logs below — Ctrl-C to stop."
echo ""

ETH_RPC_URL="$ANVIL_RPC" \
VAULT_ADDRESS="$VAULT_ADDRESS" \
ADAPTER_ADDRESS="$ADAPTER_ADDRESS" \
POLL_INTERVAL_SEC=5 \
DELTA_THRESHOLD=0.05 \
NEAR_LIVE=false \
MOCK_ETH_PRICE_USD=3000 \
RUST_LOG=optionszero_daemon=info,info \
"$DAEMON_BIN"
