// PaySecure Gateway - Multi-Region DR Operations Console Logic
document.addEventListener('DOMContentLoaded', () => {
  initTabs();
  initTopologyCanvas();
  initTelemetryChart();
  initScenarios();
  initRunbooks();
  initBCRB();
  initErrors();
  startStatusPolling();
  setupEventListeners();
});

// App State
const state = {
  activeWriter: 'ap-south-1',
  route53Target: 'ap-south-1',
  status: 'HEALTHY',
  tps: 1184,
  p99: 178,
  auroraLag: 142,
  rtt: 18.4,
  activeDrill: null,
  drillTimer: null,
  drillSeconds: 0,
  trafficPaused: false
};

// 1. Tab Switching
function initTabs() {
  const tabs = document.querySelectorAll('.nav-tab');
  const panes = document.querySelectorAll('.tab-pane');

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      panes.forEach(p => p.classList.remove('active'));

      tab.classList.add('active');
      const targetId = tab.getAttribute('data-tab');
      const pane = document.getElementById(targetId);
      if (pane) pane.classList.add('active');
    });
  });
}

// 2. Topology Canvas Animation
let canvas, ctx, animId;
let packets = [];

function initTopologyCanvas() {
  canvas = document.getElementById('topologyCanvas');
  if (!canvas) return;
  ctx = canvas.getContext('2d');

  function resize() {
    canvas.width = canvas.parentElement.clientWidth;
    canvas.height = canvas.parentElement.clientHeight;
  }
  window.addEventListener('resize', resize);
  resize();

  // Create initial packet streams
  for (let i = 0; i < 25; i++) {
    packets.push({
      progress: Math.random(),
      speed: 0.004 + Math.random() * 0.003,
      type: Math.random() > 0.4 ? 'client-to-primary' : 'replication',
      size: 2.5 + Math.random() * 2
    });
  }

  animateTopology();
}

function animateTopology() {
  if (!ctx || !canvas) return;
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  const w = canvas.width;
  const h = canvas.height;

  // Node Coordinates
  const clientPos = { x: w * 0.12, y: h * 0.5 };
  const r53Pos = { x: w * 0.28, y: h * 0.5 };
  const mumPos = { x: w * 0.48, y: h * 0.5 };
  const hydPos = { x: w * 0.86, y: h * 0.5 };

  // Draw Static Connection Lines
  ctx.lineWidth = 1.5;
  ctx.setLineDash([4, 4]);

  // Client -> Route 53
  ctx.strokeStyle = 'rgba(0, 240, 255, 0.25)';
  ctx.beginPath();
  ctx.moveTo(clientPos.x, clientPos.y);
  ctx.lineTo(r53Pos.x, r53Pos.y);
  ctx.stroke();

  // Route 53 -> Mumbai (Primary)
  ctx.strokeStyle = state.route53Target === 'ap-south-1' ? 'rgba(0, 230, 118, 0.4)' : 'rgba(255, 255, 255, 0.1)';
  ctx.beginPath();
  ctx.moveTo(r53Pos.x, r53Pos.y);
  ctx.lineTo(mumPos.x, mumPos.y);
  ctx.stroke();

  // Route 53 -> Hyderabad (Failover path)
  ctx.strokeStyle = state.route53Target === 'ap-south-2' ? 'rgba(0, 230, 118, 0.5)' : 'rgba(139, 92, 246, 0.2)';
  ctx.beginPath();
  ctx.moveTo(r53Pos.x, r53Pos.y);
  ctx.lineTo(hydPos.x, hydPos.y);
  ctx.stroke();

  // Cross-Region Replication Link (Mumbai <-> Hyderabad)
  ctx.strokeStyle = 'rgba(0, 240, 255, 0.35)';
  ctx.beginPath();
  ctx.moveTo(mumPos.x, mumPos.y);
  ctx.lineTo(hydPos.x, hydPos.y);
  ctx.stroke();

  ctx.setLineDash([]); // Reset line dash

  // Draw Animated Streaming Packets
  if (!state.trafficPaused) {
    packets.forEach(p => {
      p.progress += p.speed;
      if (p.progress > 1) p.progress = 0;

      let sx, sy, ex, ey, color;

      if (p.type === 'client-to-primary') {
        if (state.route53Target === 'ap-south-1') {
          // Client -> R53 -> Mumbai
          if (p.progress < 0.4) {
            const subP = p.progress / 0.4;
            sx = clientPos.x + (r53Pos.x - clientPos.x) * subP;
            sy = clientPos.y + (r53Pos.y - clientPos.y) * subP;
          } else {
            const subP = (p.progress - 0.4) / 0.6;
            sx = r53Pos.x + (mumPos.x - r53Pos.x) * subP;
            sy = r53Pos.y + (mumPos.y - r53Pos.y) * subP;
          }
          color = '#00f0ff';
        } else {
          // Client -> R53 -> Hyderabad
          if (p.progress < 0.4) {
            const subP = p.progress / 0.4;
            sx = clientPos.x + (r53Pos.x - clientPos.x) * subP;
            sy = clientPos.y + (r53Pos.y - clientPos.y) * subP;
          } else {
            const subP = (p.progress - 0.4) / 0.6;
            sx = r53Pos.x + (hydPos.x - r53Pos.x) * subP;
            sy = r53Pos.y + (hydPos.y - r53Pos.y) * subP;
          }
          color = '#10b981';
        }
      } else {
        // Replication packets: Mumbai -> Hyderabad
        sx = mumPos.x + (hydPos.x - mumPos.x) * p.progress;
        sy = mumPos.y + (hydPos.y - mumPos.y) * p.progress;
        color = '#8b5cf6';
      }

      ctx.beginPath();
      ctx.arc(sx, sy, p.size, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.shadowBlur = 8;
      ctx.shadowColor = color;
      ctx.fill();
      ctx.shadowBlur = 0;
    });
  }

  animId = requestAnimationFrame(animateTopology);
}

// 3. Telemetry Chart (Chart.js)
let teleChart;
const chartData = {
  labels: [],
  tps: [],
  latency: []
};

function initTelemetryChart() {
  const ctx = document.getElementById('telemetryChart');
  if (!ctx) return;

  const now = new Date();
  for (let i = 15; i >= 0; i--) {
    const t = new Date(now.getTime() - i * 2000);
    chartData.labels.push(t.toLocaleTimeString());
    chartData.tps.push(1150 + Math.floor(Math.random() * 50));
    chartData.latency.push(175 + Math.floor(Math.random() * 10));
  }

  teleChart = new Chart(ctx, {
    type: 'line',
    data: {
      labels: chartData.labels,
      datasets: [
        {
          label: 'TPS Throughput',
          data: chartData.tps,
          borderColor: '#00f0ff',
          backgroundColor: 'rgba(0, 240, 255, 0.05)',
          tension: 0.35,
          yAxisID: 'y'
        },
        {
          label: 'P99 Latency (ms)',
          data: chartData.latency,
          borderColor: '#10b981',
          backgroundColor: 'transparent',
          borderDash: [5, 5],
          tension: 0.35,
          yAxisID: 'y1'
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: {
        x: { grid: { color: 'rgba(255,255,255,0.05)' }, ticks: { color: '#64748b', font: { family: 'JetBrains Mono', size: 10 } } },
        y: { grid: { color: 'rgba(255,255,255,0.05)' }, ticks: { color: '#00f0ff' }, min: 800, max: 1400 },
        y1: { position: 'right', grid: { drawOnChartArea: false }, ticks: { color: '#10b981' }, min: 100, max: 400 }
      },
      plugins: {
        legend: { labels: { color: '#94a3b8', font: { family: 'Outfit' } } }
      }
    }
  });

  setInterval(updateTelemetry, 2000);
}

function updateTelemetry() {
  if (!teleChart) return;
  const timeStr = new Date().toLocaleTimeString();

  let curTps = state.status === 'CRITICAL_FAILURE' ? Math.floor(state.tps * 0.35) : (1150 + Math.floor(Math.random() * 60));
  let curLat = state.status === 'CRITICAL_FAILURE' ? 480 : (175 + Math.floor(Math.random() * 12));

  state.tps = curTps;
  state.p99 = curLat;

  document.getElementById('live-tps').innerHTML = `${curTps} <span class="unit">TPS</span>`;
  document.getElementById('live-p99').innerHTML = `${curLat} <span class="unit">ms</span>`;

  chartData.labels.shift();
  chartData.labels.push(timeStr);
  chartData.tps.shift();
  chartData.tps.push(curTps);
  chartData.latency.shift();
  chartData.latency.push(curLat);

  teleChart.update('none');
}

// 4. 12 Mandatory Disaster Scenarios Definition
const scenarios = [
  { id: 1, title: 'Complete Primary Region Failure', cat: 'Infrastructure', sev: 'P1-Critical', impact: '100% loss of Mumbai compute, database & network', rto: '3m 58s', rpo: '< 1s', runbook: 'RB-01' },
  { id: 2, title: 'Database Corruption in Aurora', cat: 'Data Integrity', sev: 'P1-Critical', impact: '4,800 corrupt transactions over 15 minutes', rto: '4m 15s', rpo: '15m PITR', runbook: 'RB-02' },
  { id: 3, title: 'Route 53 DNS Poisoning / Failure', cat: 'Security / DNS', sev: 'P1-Critical', impact: 'API traffic hijacked or unresolvable', rto: '2m 30s', rpo: '0s', runbook: 'RB-03' },
  { id: 4, title: 'Kafka Cluster Disk / Quorum Outage', cat: 'Messaging', sev: 'P2-High', impact: '50k msg/sec event ingestion halted', rto: '3m 20s', rpo: '< 10s', runbook: 'RB-04' },
  { id: 5, title: 'Cross-Region Network Partition', cat: 'Infrastructure', sev: 'P1-Critical', impact: 'Replication severed; split-brain danger', rto: '2m 45s', rpo: '0s (Idempotency)', runbook: 'RB-05' },
  { id: 6, title: 'KMS Cryptographic Key Compromise', cat: 'Security / CDE', sev: 'P1-Critical', impact: 'Cardholder data keys compromised', rto: '4m 50s', rpo: '0s', runbook: 'RB-06' },
  { id: 7, title: '150k TPS DDoS Flood Attack', cat: 'Security / WAF', sev: 'P2-High', impact: '125x normal peak request volume', rto: '1m 30s', rpo: '0s', runbook: 'RB-07' },
  { id: 8, title: 'Third-Party NPCI UPI Central Outage', cat: 'External Partner', sev: 'P2-High', impact: 'UPI processing network down nationwide', rto: '1m 00s', rpo: '0s', runbook: 'RB-08' },
  { id: 9, title: 'Wildcard TLS Certificate Expiry', cat: 'Infrastructure', sev: 'P2-High', impact: 'All HTTPS merchant transactions fail TLS handshake', rto: '1m 45s', rpo: '0s', runbook: 'RB-09' },
  { id: 10, title: 'Single AZ Power Outage (ap-south-1a)', cat: 'Infrastructure', sev: 'P2-High', impact: '33% compute capacity lost + 1 Aurora replica', rto: '1m 15s', rpo: '0s', runbook: 'RB-10' },
  { id: 11, title: 'Ransomware Attack on EKS Nodes', cat: 'Security', sev: 'P1-Critical', impact: 'Worker nodes encrypted & CI/CD pipeline locked', rto: '4m 40s', rpo: '0s (Isolated CDE)', runbook: 'RB-11' },
  { id: 12, title: 'Cascading Microservice Failure (Fraud Engine)', cat: 'Application', sev: 'P1-Critical', impact: 'Success rate drops from 99.8% to 42%', rto: '1m 20s', rpo: '0s', runbook: 'RB-12' }
];

function initScenarios() {
  const container = document.getElementById('scenarios-grid');
  if (!container) return;

  container.innerHTML = scenarios.map(s => `
    <div class="scenario-card" onclick="triggerDisasterSimulation(${s.id})">
      <div>
        <div class="scen-top">
          <span class="scen-id">SCENARIO ${s.id < 10 ? '0' + s.id : s.id}</span>
          <span class="scen-cat">${s.cat}</span>
        </div>
        <div class="scen-title">${s.title}</div>
        <div class="scen-desc">${s.impact}</div>
      </div>
      <div class="scen-footer">
        <span class="scen-impact">Target RTO: ${s.rto}</span>
        <button class="btn btn-sm btn-outline">Simulate Drill &rarr;</button>
      </div>
    </div>
  `).join('');
}

// 5. Trigger Scenario Simulation
window.triggerDisasterSimulation = function(id) {
  const s = scenarios.find(item => item.id === id);
  if (!s) return;

  state.activeDrill = s;
  state.status = 'CRITICAL_FAILURE';
  state.drillSeconds = 0;

  // Show Active Drill Panel
  const panel = document.getElementById('drill-active-panel');
  panel.style.display = 'block';
  document.getElementById('active-drill-title').innerText = `Simulating Disaster: [${s.runbook}] ${s.title}`;
  document.getElementById('drill-timer-rpo').innerText = s.rpo;

  // Render drill step-by-step
  const viz = document.getElementById('drill-steps-visualizer');
  viz.innerHTML = `
    <div class="drill-step-item done">[T+00s] Failure injected: ${s.title}. Automated alarms trigger across monitoring tier.</div>
    <div class="drill-step-item active">[T+30s] Route 53 health check threshold breached (3 consecutive failures). P1 PagerDuty firing.</div>
    <div class="drill-step-item pending">[T+60s] Incident Commander confirms regional outage. Emergency failover pipeline ready.</div>
    <div class="drill-step-item pending">[T+148s] Aurora PostgreSQL failover promoted Hyderabad to Primary Writer.</div>
    <div class="drill-step-item pending">[T+238s] Route 53 DNS records flipped. Traffic 100% restored.</div>
  `;

  // Start RTO stopwatch
  clearInterval(state.drillTimer);
  state.drillTimer = setInterval(() => {
    state.drillSeconds++;
    const m = String(Math.floor(state.drillSeconds / 60)).padStart(2, '0');
    const sec = String(state.drillSeconds % 60).padStart(2, '0');
    document.getElementById('drill-timer-rto').innerText = `${m}:${sec}`;
  }, 1000);

  // Update Status Badge
  const badge = document.getElementById('system-status-badge');
  badge.innerHTML = '<span class="status-dot red"></span> DRILL IN PROGRESS - FAILURE ACTIVE';
  badge.style.color = '#ef4444';
  badge.style.background = 'rgba(239, 68, 68, 0.1)';

  // Send to backend API
  fetch('/api/simulate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ scenario_id: s.id, scenario_name: s.title })
  });

  appendLog('CRITICAL', `Arena Mode Drill Initiated: Scenario ${s.id} (${s.title}).`);
  showToast(`⚠️ Disaster Injected: ${s.title}`);
};

// 6. Execute Failover Action
function executeFailover() {
  state.activeWriter = 'ap-south-2';
  state.route53Target = 'ap-south-2';
  state.status = 'OPERATING_IN_DR';

  clearInterval(state.drillTimer);

  document.getElementById('ticker-writer').innerText = 'ap-south-2';
  document.getElementById('ticker-writer').className = 'ticker-value text-purple';
  document.getElementById('dns-active-status').innerText = 'Active Route: Hyderabad (ap-south-2)';
  document.getElementById('badge-mum-role').innerText = 'FAILED / ISOLATED';
  document.getElementById('badge-mum-role').className = 'region-role badge-danger';
  document.getElementById('badge-hyd-role').innerText = 'PRIMARY WRITER';
  document.getElementById('badge-hyd-role').className = 'region-role badge-primary';

  // Mark all steps done in visualizer
  const items = document.querySelectorAll('.drill-step-item');
  items.forEach(i => {
    i.className = 'drill-step-item done';
  });

  document.getElementById('drill-step-bar').style.width = '100%';

  const badge = document.getElementById('system-status-badge');
  badge.innerHTML = '<span class="status-dot green"></span> OPERATING IN DR (HYDERABAD)';
  badge.style.color = '#10b981';
  badge.style.background = 'rgba(16, 185, 129, 0.1)';

  fetch('/api/failover', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ reason: 'Arena Mode Automated Failover Execution' })
  });

  appendLog('SUCCESS', 'Failover Complete: All traffic running on Hyderabad (ap-south-2). RTO: 3m 58s. RPO: < 1s.');
  showToast('✅ Multi-Region Failover Completed Successfully!');
}

// 7. Failback Action
function executeFailback() {
  state.activeWriter = 'ap-south-1';
  state.route53Target = 'ap-south-1';
  state.status = 'HEALTHY';
  state.activeDrill = null;
  clearInterval(state.drillTimer);

  document.getElementById('drill-active-panel').style.display = 'none';
  document.getElementById('ticker-writer').innerText = 'ap-south-1';
  document.getElementById('ticker-writer').className = 'ticker-value text-success';
  document.getElementById('dns-active-status').innerText = 'Active Route: Mumbai (ap-south-1)';
  document.getElementById('badge-mum-role').innerText = 'PRIMARY WRITER';
  document.getElementById('badge-mum-role').className = 'region-role badge-primary';
  document.getElementById('badge-hyd-role').innerText = 'HOT STANDBY';
  document.getElementById('badge-hyd-role').className = 'region-role badge-secondary';

  const badge = document.getElementById('system-status-badge');
  badge.innerHTML = '<span class="status-dot green"></span> SYSTEM OPERATIONAL';
  badge.style.color = '#10b981';
  badge.style.background = 'rgba(16, 185, 129, 0.1)';

  fetch('/api/failback', { method: 'POST' });
  appendLog('INFO', 'Failback Completed: Nominal topology restored in Mumbai (ap-south-1).');
  showToast('🔄 Failback Completed: Primary restored to Mumbai.');
}

// 8. Runbooks Viewer
function initRunbooks() {
  const listEl = document.getElementById('runbook-nav-list');
  const viewerEl = document.getElementById('runbook-viewer');
  if (!listEl || !viewerEl) return;

  listEl.innerHTML = scenarios.map((s, idx) => `
    <div class="rb-item ${idx === 0 ? 'active' : ''}" onclick="selectRunbook(${s.id})">
      <div class="rb-id">${s.runbook} &bull; ${s.sev}</div>
      <div class="rb-name">${s.title}</div>
    </div>
  `).join('');

  selectRunbook(1);
}

window.selectRunbook = function(id) {
  const s = scenarios.find(item => item.id === id);
  if (!s) return;

  document.querySelectorAll('.rb-item').forEach(el => el.classList.remove('active'));
  const activeItem = [...document.querySelectorAll('.rb-item')].find(el => el.innerText.includes(s.runbook));
  if (activeItem) activeItem.classList.add('active');

  const viewer = document.getElementById('runbook-viewer');
  viewer.innerHTML = `
    <div class="runbook-doc">
      <div style="display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:1.5rem;">
        <div>
          <span class="stat-badge cyan">${s.runbook} &bull; ${s.cat}</span>
          <h2 style="margin-top:0.5rem;">${s.title}</h2>
          <p class="text-muted">Mandatory 10-Section Standard &bull; Severity: <span class="text-danger">${s.sev}</span></p>
        </div>
        <button class="btn btn-primary btn-sm" onclick="triggerDisasterSimulation(${s.id})">Test in Arena Mode</button>
      </div>

      <div style="background:rgba(255,255,255,0.03); padding:1rem; border-radius:8px; margin-bottom:1.5rem; font-family:var(--font-mono); font-size:0.8rem;">
        <div><strong>Detection Metric:</strong> CloudWatch AuroraGlobalDBReplicationLag > 500ms OR Route 53 Status &lt; 1</div>
        <div><strong>Target RTO:</strong> ${s.rto} | <strong>Target RPO:</strong> ${s.rpo}</div>
        <div><strong>Regulatory Escalation:</strong> Mandatory reporting to RBI within 2 hours of P1 incident</div>
      </div>

      <h3>Section 1 &ndash; 3: Detection &amp; Immediate Assessment (0 &ndash; 2 mins)</h3>
      <p class="text-secondary" style="margin-bottom:1rem;">Automated CloudWatch alarms trigger Incident Commander paging. Secondary region readiness composite evaluated via Route 53 health check probes.</p>

      <h3>Section 4 &ndash; 6: Failover Command-Level Procedure (2 &ndash; 5 mins)</h3>
      <pre style="background:#000; padding:1rem; border-radius:6px; font-family:var(--font-mono); font-size:0.78rem; color:#00f0ff; overflow-x:auto; margin-bottom:1.5rem;">
# Step 1: Promote Aurora Global Database secondary in Hyderabad
aws rds failover-global-cluster \\
  --global-cluster-identifier paysecure-global \\
  --target-db-cluster-identifier arn:aws:rds:ap-south-2:123456789012:cluster:paysecure-secondary

# Step 2: Scale EKS compute workloads to 100% capacity
kubectl --context paysecure-dr -n paysecure scale deployment payment-api --replicas=12

# Step 3: Shift Route 53 DNS resolution to Hyderabad ALB
aws route53 change-resource-record-sets --hosted-zone-id Z1234567890 --change-batch file://dns-failover.json
      </pre>

      <h3>Section 7: Regulatory Communication Protocol</h3>
      <div style="background:rgba(0,0,0,0.25); border-left:3px solid var(--accent-cyan); padding:0.8rem; font-family:var(--font-mono); font-size:0.75rem;">
        Subject: Mandatory P1 Incident Notification - PaySecure Gateway (PPA Licence: RBI/2024/PPA-4829)<br>
        To: incident-reporting@rbi.org.in, payment-security@npci.org.in<br>
        Status: Automated Failover Initiated to ap-south-2 (Hyderabad). Zero customer data loss.
      </div>
    </div>
  `;
};

// 9. BCRB Board Defense
const bcrbQuestions = [
  { persona: 'cto', role: 'Chief Technology Officer (Rajesh Mehta)', q: 'Challenge 1: What happens when a transaction is being processed in Mumbai and the region fails mid-transaction?', a: 'Every payment request is assigned a deterministic Client-Generated Idempotency Key stored in DynamoDB Global Tables before upstream gateway execution. If Mumbai fails mid-transaction, client timeouts trigger automatic retry. The secondary region in Hyderabad looks up the idempotency key: if PENDING, it initiates an out-of-band status inquiry with the issuing bank/NPCI; if CAPTURED, it returns success without debiting again. If the bank transaction was never initiated, it processes freshly. Double debit risk is mathematically zero.' },
  { persona: 'cto', role: 'Chief Technology Officer (Rajesh Mehta)', q: 'Challenge 2: Real-world RTO with DNS TTL propagation, connection pools and retry storms?', a: 'Route 53 health check detection takes 30s (3 failures @ 10s). Fast-failover DNS TTL is set to 30s. Application SDKs use client-side failover to the secondary endpoint on 2 consecutive 5xx errors without waiting for DNS propagation. Envoy sidecars shed stale connection pools via aggressive keepalive timeouts (15s). Peak retry storms are absorbed by the warm EKS cluster auto-scaling with PodDisruptionBudgets. Total tested RTO is 3m 58s (under the 5-minute mandate).' },
  { persona: 'cro', role: 'Chief Risk Officer (Priya Krishnan)', q: 'Challenge 3: Split-brain financial exposure if both regions process independently for 3 minutes?', a: 'During a 3-minute network partition at 1,200 TPS, ~216,000 transactions flow through. However, because our architecture is Active-Passive (Hot Standby), Hyderabad NEVER accepts writes until promoted. In an Active-Active split-brain, DynamoDB Global Tables enforce last-writer-wins per idempotency partition, and partner bank UPI switches prevent duplicate clearing. Automated split-brain reconciler script flags state discrepancies within 4 minutes with ₹0.00 unrecoverable exposure.' },
  { persona: 'compliance', role: 'Head of Regulatory Compliance (Anand Sharma)', q: 'Challenge 5: Cardholder data residency during failover & non-Indian routing proof?', a: 'All CDE databases (Aurora, DynamoDB, Redis) replicate exclusively between ap-south-1 (Mumbai) and ap-south-2 (Hyderabad) via AWS Inter-Region Peering within the Indian geopolitical boundary. Zero traffic traverses public Internet or foreign data centers. CloudTrail logs, VPC flow logs, and Route 53 routing policies are cryptographically signed and archived for RBI auditor inspection.' },
  { persona: 'vp-eng', role: 'VP Engineering (Vikram Patel)', q: 'Challenge 7: How does an 8-person platform engineering team maintain this system sustainably?', a: 'By selecting Active-Passive (Hot Standby) rather than Active-Active, operational burden is reduced by ~65%. Standby infrastructure in Hyderabad is managed identically through declarative Terraform 1.5+ modules and ArgoCD GitOps pipelines. On-call rotations feature automated runbook orchestration scripts that execute failover with single-command confirmation, preventing cognitive fatigue.' },
  { persona: 'auditor', role: 'External Auditor (Sarah Chen)', q: 'Challenge 8: Spend increased to 1.7x, board approved 1.4x budget. What can we cut?', a: 'Through 3-year Compute Savings Plans and Aurora Database Reserved Instances, we reduced infrastructure spend from 1.74x on-demand down to 1.62x (₹12.98 Cr/yr). Cutting warm EKS standby nodes to cold spot capacity saves an additional 0.12x (achieving 1.50x), but increases RTO from 3m 58s to 6m 30s, risking regulatory fines of up to ₹5 Crore from RBI. The board-approved 1.62x model pays for itself by preventing a single 1-hour outage (₹1.09 Cr protected).' }
];

function initBCRB() {
  const container = document.getElementById('bcrb-cards-container');
  if (!container) return;

  function render(filter) {
    const list = filter === 'all' ? bcrbQuestions : bcrbQuestions.filter(q => q.persona === filter);
    container.innerHTML = list.map(q => `
      <div class="bcrb-card">
        <div class="bcrb-card-top">
          <span class="bcrb-persona-badge">${q.role}</span>
          <span class="stat-badge green">BCRB APPROVED</span>
        </div>
        <div class="bcrb-q">${q.q}</div>
        <div class="bcrb-a">${q.a}</div>
      </div>
    `).join('');
  }

  render('all');

  document.querySelectorAll('.persona-chip').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('.persona-chip').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      render(chip.getAttribute('data-persona'));
    });
  });
}

// 10. Deliberate Errors View
const deliberateErrors = [
  { num: '01', title: 'Duplicate Case Study 4 Header', loc: 'Project Brief Page 37', detail: 'Case Study 4 ("AWS ap-south-1 Power Event April 2021") was duplicated word-for-word in the text specification.', fix: 'De-duplicated and merged into single analytical study.' },
  { num: '02', title: 'Regulatory Fines Inconsistency (₹5 Cr vs ₹2 Cr)', loc: 'Brief Page 4 vs Page 24', detail: 'Section A1.2 cited penalty of up to ₹5 Crore, while Section B1 cited ₹2 Crore for identical non-compliance.', fix: 'Reconciled to Payment and Settlement Systems Act, 2007 (Section 26 & 30): ₹5 Crore for systemic Tier-1 gateway disruption.' },
  { num: '03', title: 'DynamoDB Global Tables Pricing Multiplier (1.5x vs 1.25x)', loc: 'Brief Page 55', detail: 'Listed DynamoDB Global Table replicated WCU as 1.5x normal cost.', fix: 'Corrected to official AWS Pricing: Replicated Write Units (rWCU) are billed at 1.25x in ap-south-2.' },
  { num: '04', title: 'Terraform Circular Dependency in Aurora Global Database', loc: 'Brief Page 59', detail: 'aws_rds_global_cluster referenced primary cluster ARN while primary cluster referenced global cluster ID.', fix: 'Fixed in Terraform 1.5+ by declaring global cluster independently without source_db_cluster_identifier.' },
  { num: '05', title: 'Route 53 Detection Math & Unmanaged Failover CLI', loc: 'Brief Page 10 & 66', detail: 'Route 53 RTO calculation omitted DNS cache TTL delay (45s detection + 60s TTL = 105s), and CLI command referenced unmanaged failover.', fix: 'Updated to managed failover-global-cluster command and synchronized 30s fast-TTL profile.' }
];

function initErrors() {
  const container = document.getElementById('errors-list-container');
  if (!container) return;

  container.innerHTML = deliberateErrors.map(e => `
    <div class="error-item-card">
      <div class="err-header">
        <span class="err-num">ERROR #${e.num} IDENTIFIED</span>
        <span class="err-loc">${e.loc}</span>
      </div>
      <div class="err-title">${e.title}</div>
      <div class="err-detail">${e.detail}</div>
      <div class="err-fix"><strong>Architecture Fix Applied:</strong> ${e.fix}</div>
    </div>
  `).join('');
}

// 11. Event Listeners
function setupEventListeners() {
  document.getElementById('btn-emergency-failover').addEventListener('click', () => {
    if (confirm('AUTHORIZATION REQUIRED: Execute emergency failover to ap-south-2 (Hyderabad)?')) {
      executeFailover();
    }
  });

  document.getElementById('btn-drill-failover').addEventListener('click', () => {
    executeFailover();
  });

  document.getElementById('btn-drill-cancel').addEventListener('click', () => {
    executeFailback();
  });

  document.getElementById('btn-failback').addEventListener('click', () => {
    executeFailback();
  });

  document.getElementById('btn-deep-health').addEventListener('click', () => {
    fetch('/api/health/deep')
      .then(res => res.json())
      .then(data => {
        showToast(`Deep Health Probe: ${data.status} across all 4 data engines`);
        appendLog('INFO', `Health Probe Result: Aurora DB (${data.components.aurora_postgresql.latency_ms.toFixed(1)}ms), DynamoDB (${data.components.dynamodb_global.latency_ms.toFixed(1)}ms).`);
      });
  });

  document.getElementById('btn-reconcile-split').addEventListener('click', () => {
    fetch('/api/reconcile', { method: 'POST' })
      .then(res => res.json())
      .then(data => {
        showToast(`✅ Split-Brain Reconciled: ${data.reconciled.toLocaleString()} transactions checked. Zero exposure.`);
        appendLog('SUCCESS', `Split-Brain Ledger Audit: 1,842 duplicate requests blocked by idempotency engine.`);
      });
  });

  document.getElementById('btn-toggle-traffic').addEventListener('click', (e) => {
    state.trafficPaused = !state.trafficPaused;
    e.target.innerText = state.trafficPaused ? 'Resume Animation' : 'Pause Animation';
  });

  document.getElementById('btn-clear-logs').addEventListener('click', () => {
    document.getElementById('log-stream-box').innerHTML = '';
  });
}

function appendLog(level, msg) {
  const box = document.getElementById('log-stream-box');
  if (!box) return;
  const time = new Date().toLocaleTimeString();
  const div = document.createElement('div');
  div.className = 'log-line';
  div.innerHTML = `
    <span class="log-time">[${time}]</span>
    <span class="log-level-${level}">[${level}]</span>
    <span class="log-msg">${msg}</span>
  `;
  box.prepend(div);
}

function showToast(msg) {
  const container = document.getElementById('toast-container');
  if (!container) return;
  const toast = document.createElement('div');
  toast.className = 'toast';
  toast.innerHTML = `<span>${msg}</span>`;
  container.appendChild(toast);
  setTimeout(() => {
    toast.remove();
  }, 4000);
}

function startStatusPolling() {
  fetch('/api/status')
    .then(res => res.json())
    .then(data => {
      if (data.logs) {
        data.logs.forEach(l => appendLog(l.level, l.msg));
      }
    })
    .catch(() => {});
}
