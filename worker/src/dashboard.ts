/**
 * Dashboard HTML — shadcn-inspired. Minimal, dark, data-dense.
 * No gradients, no glow, no glassmorphism.
 */
export function renderDashboard(): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>OptionZero — Vault Monitor</title>
  <meta name="description" content="Live monitoring dashboard for the OptionZero delta-neutral vault on Sepolia." />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Geist+Mono:wght@400;500&family=Inter:wght@400;500;600&display=swap" rel="stylesheet" />
  <style>
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }

    :root {
      --bg: #09090b;
      --bg-card: #09090b;
      --bg-muted: #16161a;
      --border: #25252a;
      --border-hover: #38383f;
      --text: #b4b4bc;
      --text-value: #c9b99a;
      --text-secondary: #87878f;
      --text-muted: #4a4a52;
      --green: #5a9e6f;
      --red: #c75a5a;
      --amber: #b8a44e;
      --font: 'Inter', -apple-system, system-ui, sans-serif;
      --mono: 'Geist Mono', 'SF Mono', 'Consolas', monospace;
      --radius: 8px;
    }

    body {
      font-family: var(--font);
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }

    .container {
      max-width: 960px;
      margin: 0 auto;
      padding: 3rem 1.5rem;
    }

    /* ── Header ──────────────────────────── */
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 2rem;
      padding-bottom: 1.5rem;
      border-bottom: 1px solid var(--border);
    }

    .title-group {
      display: flex;
      align-items: baseline;
      gap: 0.75rem;
    }

    .title-group h1 {
      font-size: 0.875rem;
      font-weight: 600;
      letter-spacing: -0.01em;
    }

    .separator {
      color: var(--text-muted);
      font-weight: 300;
    }

    .subtitle {
      font-size: 0.875rem;
      color: var(--text-secondary);
      font-weight: 400;
    }

    .header-right {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .network-tag {
      font-family: var(--mono);
      font-size: 0.7rem;
      color: var(--text-muted);
      padding: 0.25rem 0.5rem;
      border: 1px solid var(--border);
      border-radius: 4px;
    }

    .status-indicator {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      font-size: 0.75rem;
      font-weight: 500;
    }

    .status-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
    }

    .status-dot.green { background: var(--green); }
    .status-dot.amber { background: var(--amber); }
    .status-dot.red { background: var(--red); }

    /* ── Metrics Grid ────────────────────── */
    .metrics {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 0;
      border: 1px solid var(--border);
      border-radius: var(--radius);
      margin-bottom: 1.5rem;
      overflow: hidden;
    }

    .metric {
      padding: 1.25rem;
      border-right: 1px solid var(--border);
    }

    .metric:last-child { border-right: none; }

    .metric-label {
      font-size: 0.7rem;
      font-weight: 500;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 0.5rem;
    }

    .metric-value {
      font-family: var(--mono);
      font-size: 1.375rem;
      font-weight: 500;
      letter-spacing: -0.02em;
      line-height: 1;
      margin-bottom: 0.35rem;
      color: var(--text-value);
    }

    .metric-sub {
      font-family: var(--mono);
      font-size: 0.675rem;
      color: var(--text-muted);
    }

    /* ── Coverage ────────────────────────── */
    .section {
      border: 1px solid var(--border);
      border-radius: var(--radius);
      margin-bottom: 1.5rem;
      overflow: hidden;
    }

    .section-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 0.875rem 1.25rem;
      border-bottom: 1px solid var(--border);
    }

    .section-title {
      font-size: 0.75rem;
      font-weight: 500;
      color: var(--text-secondary);
    }

    .section-value {
      font-family: var(--mono);
      font-size: 0.8rem;
      font-weight: 500;
      color: var(--text-value);
    }

    .section-body {
      padding: 1.25rem;
    }

    .bar-track {
      width: 100%;
      height: 4px;
      background: var(--bg-muted);
      border-radius: 2px;
      overflow: hidden;
    }

    .bar-fill {
      height: 100%;
      border-radius: 2px;
      background: var(--text-value);
      transition: width 0.8s ease;
    }

    .bar-fill.warning { background: var(--amber); }
    .bar-fill.danger { background: var(--red); }

    .bar-labels {
      display: flex;
      justify-content: space-between;
      margin-top: 0.625rem;
      font-family: var(--mono);
      font-size: 0.65rem;
      color: var(--text-muted);
    }

    /* ── Intents ─────────────────────────── */
    .intent-row {
      display: flex;
      align-items: center;
      gap: 0.875rem;
      padding: 0.75rem 1.25rem;
      border-bottom: 1px solid var(--border);
    }

    .intent-row:last-child { border-bottom: none; }

    .intent-badge {
      font-family: var(--mono);
      font-size: 0.65rem;
      font-weight: 500;
      padding: 0.2rem 0.5rem;
      border-radius: 3px;
      flex-shrink: 0;
    }

    .intent-badge.resize {
      background: rgba(250, 250, 250, 0.06);
      color: var(--text);
    }

    .intent-badge.settle {
      background: rgba(234, 179, 8, 0.1);
      color: var(--amber);
    }

    .intent-badge.funding {
      background: rgba(90, 158, 111, 0.1);
      color: var(--green);
    }

    .intent-badge.idle {
      background: rgba(34, 197, 94, 0.08);
      color: var(--green);
    }

    .intent-text {
      font-size: 0.8rem;
      color: var(--text-secondary);
    }

    .intent-detail {
      margin-left: auto;
      font-family: var(--mono);
      font-size: 0.7rem;
      color: var(--text-muted);
    }

    /* ── HL Position ────────────────────── */
    .hl-grid {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 0;
    }

    .hl-cell {
      padding: 0.875rem 1.25rem;
      border-right: 1px solid var(--border);
    }

    .hl-cell:last-child { border-right: none; }

    .hl-label {
      font-size: 0.65rem;
      font-weight: 500;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
      margin-bottom: 0.35rem;
    }

    .hl-value {
      font-family: var(--mono);
      font-size: 0.875rem;
      font-weight: 500;
      color: var(--text-value);
    }

    /* ── Footer ──────────────────────────── */
    footer {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-top: 1.5rem;
      border-top: 1px solid var(--border);
      font-size: 0.7rem;
      color: var(--text-muted);
    }

    footer a {
      color: var(--text-secondary);
      text-decoration: none;
    }

    footer a:hover { color: var(--text); }

    @media (max-width: 640px) {
      .metrics { grid-template-columns: 1fr 1fr; }
      .metric { border-bottom: 1px solid var(--border); }
      .metric:nth-child(2) { border-right: none; }
      .metric:nth-child(3), .metric:nth-child(4) { border-bottom: none; }
      .header-right { display: none; }
      .metric-value { font-size: 1.125rem; }
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="title-group">
        <h1>OptionZero</h1>
        <span class="separator">/</span>
        <span class="subtitle">vault monitor</span>
      </div>
      <div class="header-right">
        <span class="network-tag">sepolia</span>
        <div class="status-indicator">
          <div class="status-dot green" id="statusDot"></div>
          <span id="statusLabel">loading</span>
        </div>
      </div>
    </header>

    <div class="metrics">
      <div class="metric">
        <div class="metric-label">TVL</div>
        <div class="metric-value" id="tvl">&mdash;</div>
        <div class="metric-sub" id="tvlSub">&mdash;</div>
      </div>
      <div class="metric">
        <div class="metric-label">Hedged</div>
        <div class="metric-value" id="notional">&mdash;</div>
        <div class="metric-sub" id="notionalSub">&mdash;</div>
      </div>
      <div class="metric">
        <div class="metric-label">Funding</div>
        <div class="metric-value" id="funding">&mdash;</div>
        <div class="metric-sub" id="fundingSub">&mdash;</div>
      </div>
      <div class="metric">
        <div class="metric-label">Pending Exit</div>
        <div class="metric-value" id="pending">&mdash;</div>
        <div class="metric-sub" id="pendingSub">&mdash;</div>
      </div>
    </div>

    <div class="section">
      <div class="section-header">
        <span class="section-title">Hedge coverage</span>
        <span class="section-value" id="coveragePct">&mdash;</span>
      </div>
      <div class="section-body">
        <div class="bar-track">
          <div class="bar-fill" id="coverageBar" style="width:0%"></div>
        </div>
        <div class="bar-labels">
          <span>0%</span>
          <span id="imbalanceLabel">&mdash;</span>
          <span>100%</span>
        </div>
      </div>
    </div>

    <div class="section">
      <div class="section-header">
        <span class="section-title">Hyperliquid position</span>
        <span class="section-value" id="hlStatus" style="color:var(--text-muted);font-size:0.65rem">&mdash;</span>
      </div>
      <div class="hl-grid">
        <div class="hl-cell">
          <div class="hl-label">Size</div>
          <div class="hl-value" id="hlSize">&mdash;</div>
        </div>
        <div class="hl-cell">
          <div class="hl-label">Entry</div>
          <div class="hl-value" id="hlEntry">&mdash;</div>
        </div>
        <div class="hl-cell">
          <div class="hl-label">Unreal. PnL</div>
          <div class="hl-value" id="hlPnl">&mdash;</div>
        </div>
        <div class="hl-cell">
          <div class="hl-label">Margin Used</div>
          <div class="hl-value" id="hlMargin">&mdash;</div>
        </div>
      </div>
    </div>

    <div class="section">
      <div class="section-header">
        <span class="section-title">Intents</span>
        <span class="section-value" style="color:var(--text-muted);font-size:0.65rem" id="lastUpdate">&mdash;</span>
      </div>
      <div id="intentList">
        <div class="intent-row">
          <span class="intent-badge idle">IDLE</span>
          <span class="intent-text">Waiting for data…</span>
        </div>
      </div>
    </div>

    <footer>
      <span>delta-neutral synthetic vault &middot; poc</span>
      <a href="https://github.com/fepvenancio/optionsZero" target="_blank">github ↗</a>
    </footer>
  </div>

  <script>
    const REFRESH = 15000;

    function fmtEth(wei) {
      if (!wei || wei === '0') return '0.00';
      const s = wei.padStart(19, '0');
      return (s.slice(0, s.length - 18) || '0') + '.' + s.slice(s.length - 18, s.length - 16);
    }

    function compact(v) {
      const n = parseFloat(v);
      if (n >= 1000) return (n/1000).toFixed(1) + 'k';
      if (n >= 1) return n.toFixed(2);
      return n.toFixed(4);
    }

    function update(d) {
      const tvl = fmtEth(d.totalAssetsWei);
      const not = fmtEth(d.hedgedNotionalWei);
      const pen = fmtEth(d.pendingRedemptionWei);

      document.getElementById('tvl').textContent = compact(tvl) + ' ETH';
      document.getElementById('tvlSub').textContent = BigInt(d.totalAssetsWei).toLocaleString() + ' wei';
      document.getElementById('notional').textContent = compact(not) + ' ETH';
      document.getElementById('notionalSub').textContent = BigInt(d.hedgedNotionalWei).toLocaleString() + ' wei';

      const f = Number(d.accruedFunding);
      const fEl = document.getElementById('funding');
      fEl.textContent = (f >= 0 ? '+' : '') + (f / 1e18).toFixed(8);
      fEl.style.color = f >= 0 ? 'var(--green)' : 'var(--red)';
      document.getElementById('fundingSub').textContent = d.accruedFunding + ' raw';

      const pn = parseFloat(pen);
      document.getElementById('pending').textContent = pn > 0 ? compact(pen) + ' ETH' : 'none';
      document.getElementById('pending').style.color = pn > 0 ? 'var(--amber)' : 'var(--text-muted)';
      document.getElementById('pendingSub').textContent = pn > 0 ? BigInt(d.pendingRedemptionWei).toLocaleString() + ' wei' : 'no pending exits';

      // Coverage
      const tvlN = parseFloat(tvl);
      const notN = parseFloat(not);
      const cov = tvlN > 0 ? Math.min(100, (notN / tvlN) * 100) : 0;
      document.getElementById('coveragePct').textContent = cov.toFixed(1) + '%';

      const bar = document.getElementById('coverageBar');
      bar.style.width = cov + '%';
      bar.className = 'bar-fill' + (cov < 80 ? ' danger' : cov < 95 ? ' warning' : '');

      document.getElementById('imbalanceLabel').textContent = d.imbalanceBps + ' bps imbalance';

      // Status
      const dot = document.getElementById('statusDot');
      const label = document.getElementById('statusLabel');
      dot.className = 'status-dot';
      if (d.imbalanceBps === 0) {
        dot.classList.add('green');
        label.textContent = 'balanced';
      } else if (d.imbalanceBps <= 500) {
        dot.classList.add('amber');
        label.textContent = 'drifting';
      } else {
        dot.classList.add('red');
        label.textContent = 'rebalancing';
      }

      // Hyperliquid position
      if (d.hlPosition) {
        const hl = d.hlPosition;
        const sz = parseFloat(hl.szi || '0');
        document.getElementById('hlSize').textContent = sz !== 0 ? Math.abs(sz).toFixed(4) + ' ETH' : 'none';
        document.getElementById('hlSize').style.color = sz < 0 ? 'var(--red)' : sz > 0 ? 'var(--green)' : 'var(--text-muted)';
        document.getElementById('hlEntry').textContent = hl.entryPx ? '$' + parseFloat(hl.entryPx).toFixed(2) : '—';
        const pnl = parseFloat(hl.unrealizedPnl || '0');
        const pnlEl = document.getElementById('hlPnl');
        pnlEl.textContent = (pnl >= 0 ? '+' : '') + '$' + pnl.toFixed(4);
        pnlEl.style.color = pnl >= 0 ? 'var(--green)' : 'var(--red)';
        document.getElementById('hlMargin').textContent = '$' + parseFloat(hl.marginUsed || '0').toFixed(2);
        document.getElementById('hlStatus').textContent = sz !== 0 ? 'SHORT' : 'no position';
        document.getElementById('hlStatus').style.color = sz !== 0 ? 'var(--red)' : 'var(--text-muted)';
      }

      // Intents
      const list = document.getElementById('intentList');
      if (d.intents.length === 0) {
        list.innerHTML = '<div class="intent-row"><span class="intent-badge idle">IDLE</span><span class="intent-text">No active intents — keeper is idle</span><span class="intent-detail">Ø</span></div>';
      } else {
        list.innerHTML = d.intents.map(i => {
          const isR = i.kind === 'RESIZE_SHORT_PERP';
          const isF = i.kind === 'SETTLE_FUNDING';
          const badge = isR ? 'resize' : isF ? 'funding' : 'settle';
          const label = isR ? 'RESIZE' : isF ? 'FUNDING' : 'SETTLE';
          const absWei = (i.sizeDeltaWei || '0').replace('-','');
          let detail, desc;
          if (isR) {
            detail = (i.direction === 'INCREASE_SHORT' ? '↑ ' : '↓ ') + compact(fmtEth(absWei)) + ' ETH';
            desc = (i.direction === 'INCREASE_SHORT' ? 'Increase' : 'Decrease') + ' short perp';
          } else if (isF) {
            detail = (f / 1e18).toFixed(8) + ' ETH';
            desc = 'Settle accrued funding';
          } else {
            detail = compact(fmtEth(i.pendingSharesWei || '0')) + ' ETH';
            desc = 'Settle pending redemption batch';
          }
          return '<div class="intent-row"><span class="intent-badge '+badge+'">'+label+'</span><span class="intent-text">'+desc+'</span><span class="intent-detail">'+detail+'</span></div>';
        }).join('');
      }

      document.getElementById('lastUpdate').textContent = new Date(d.timestamp).toLocaleTimeString();
    }

    async function poll() {
      try {
        const r = await fetch('/status');
        if (r.ok) update(await r.json());
      } catch(e) { console.error(e); }
    }

    poll();
    setInterval(poll, REFRESH);
  </script>
</body>
</html>`;
}
