# devops-tch-practice
Sr. DevOps practice for **The Clearing House** — financial payments company.
Everything runs locally on **Mac M1 with OrbStack**. No AWS account needed.

---

## Prerequisites

| Tool | Install | Check |
|------|---------|-------|
| OrbStack | [orbstack.dev](https://orbstack.dev) | `orb version` |
| Docker (via OrbStack) | included | `docker info` |
| kubectl (via OrbStack) | included | `kubectl version` |
| Python 3 | included on Mac | `python3 --version` |

> OrbStack provides both Docker and a built-in Kubernetes cluster (`orbstack` context).  
> No separate `kubectl` or `minikube` install needed.

---

## What's in this repo

```
devops-tch-practice/
├── app/                        ← FastAPI payment service (golden signals + structured logs)
├── k8s/
│   ├── app/payment-deployment.yaml   ← K8s deployment (HPA, non-root, readiness probes)
│   ├── base/pod-security.yaml        ← Namespace PodSecurity + NetworkPolicy
│   ├── policies/no-privileged.yaml   ← OPA Gatekeeper policy (Policy as Code)
│   ├── vault/dev_mode.sh             ← Vault KV + dynamic PostgreSQL secrets demo
│   └── apply_and_test.sh             ← Installs Gatekeeper, applies policies, runs test
├── observability/
│   ├── docker-compose.yml            ← Full stack: app + Vault + Postgres + ELK + Grafana
│   ├── generate_traffic.sh           ← Seeds payment traffic so dashboards show data
│   ├── grafana/dashboards/           ← Pre-built Payment SLOs dashboard (auto-loads)
│   └── prometheus/alerts.yml         ← 5 golden signal alerts wired to the app
├── .github/workflows/secure-pipeline.yml  ← CI/CD reference (SAST → scan → DAST → prod)
├── Jenkinsfile                        ← Jenkins equivalent
├── terraform/envs/main.tf             ← Multi-region DR on AWS (reference)
└── shutdown.sh                        ← Stops everything cleanly
```

---

## Step-by-step demo

### Step 1 — Start the full stack

```bash
cd devops-tch-practice/observability
bash observability_stack.sh
```

Wait for all containers to be healthy (~40s for Elasticsearch):

```bash
docker compose ps
```

All 10 services should show `Up` or `(healthy)`:

| Service | URL | What it is |
|---------|-----|-----------|
| Payment App | http://localhost:8080/health | FastAPI payment microservice |
| Prometheus | http://localhost:9090 | Metrics scraper |
| Grafana | http://localhost:3000 | Dashboards — admin / admin |
| Alertmanager | http://localhost:9093 | Alert routing |
| Vault | http://localhost:8200 | Secret management — token: `root` |
| Kibana | http://localhost:5601 | Log search UI |
| Elasticsearch | http://localhost:9200 | Log storage |

---

### Step 2 — Generate payment traffic

Open a second terminal:

```bash
cd devops-tch-practice/observability
bash generate_traffic.sh &
```

This hits `/api/payments`, `/api/transactions`, and `/api/settlements` every 0.4s, producing realistic golden signal metrics.

---

### Step 3 — Grafana: Payment SLOs dashboard

#### 3a. View the pre-built dashboard

1. Open **http://localhost:3000**
2. Log in: `admin` / `admin`
3. Click the **hamburger menu (☰)** top-left → **Dashboards**
4. Click **Payment SLOs — TCH**

The dashboard auto-refreshes every 5 seconds. If panels show "No data", confirm `generate_traffic.sh` is running (Step 2).

You'll see 6 live panels:

| Panel | Golden Signal | What to say |
|-------|--------------|------------------------------|
| Payment Request Rate | Traffic | "We alert when rate is 2× the 30-min baseline — catches DDoS and viral spikes before customers feel it" |
| 5xx Error Rate | Errors | "SLO is 99.9% success rate. Alert fires at >0.1% error rate sustained for 2 minutes" |
| p99 & p50 Latency | Latency | "The 5% slow-path in the app drives p99 tail latency. Alert fires when p99 exceeds 500ms" |
| In-flight Requests | Saturation | "4th golden signal — shows queue depth before the service saturates. Alert at >50 in-flight" |
| Payment Errors by Type | Business | "Beyond the four signals we track domain errors: db_timeout, invalid_id — bridges ops and product" |
| Payment Amount Distribution | Business | "p99 transaction size is a fraud signal — sudden spike in large amounts at 3am is an anomaly" |

---

#### 3b. Run PromQL queries — two ways

Every query below can be run **in the Grafana UI** (visual) or **from the terminal** (instant, no browser needed). Use whichever fits the moment — both hit the same Prometheus API.

**Quick bash reference — all golden signals at once:**
```bash
bash observability/promql.sh --all
```

**Grafana Explore — how to switch to Code mode:**
1. Click **☰** → **Explore** (compass icon)
2. In the query panel, find the **`Builder | Code`** toggle on the right side of the `A (Prometheus)` row — click **Code**
3. The dropdowns disappear and a plain text box appears — paste your PromQL there
4. Press **Shift+Enter** or click **Run query**
5. Set the time range (top right) to **Last 15 minutes**

---

**Query 1 — Traffic: request rate per endpoint**

*Grafana UI — paste in Code mode:*
```promql
sum(rate(http_requests_total{job="tch-payment-app"}[1m])) by (endpoint)
```

*Bash:*
```bash
bash observability/promql.sh --traffic
```
```
━━━ TRAFFIC — Request Rate (rps) by endpoint
  endpoint=/api/payments       1.378
  endpoint=/api/transactions   1.378
  endpoint=/api/settlements    1.378
  endpoint=/api/payments/...   0.355
```

- `rate()` computes per-second average over the time window
- `[1m]` = 1-minute window — fast for live incident detection; use `[5m]` in alert rules to reduce noise
- `by (endpoint)` = split the result per endpoint label

> *Say: "This is the traffic golden signal. A sudden drop to zero on /api/payments is the first sign of an outage — before any customer complains."*

---

**Query 2 — Errors: 5xx error rate as a percentage**

*Grafana UI — paste in Code mode:*
```promql
sum(rate(http_requests_total{job="tch-payment-app",status_code=~"5.."}[1m]))
/
sum(rate(http_requests_total{job="tch-payment-app"}[1m]))
* 100
```

*Bash:*
```bash
bash observability/promql.sh --errors
```
```
━━━ ERRORS — 5xx Error Rate %
  (all)                        0.787

━━━ ERRORS — Count by status code
  endpoint=/api/payments  status_code=200    1.333
  endpoint=/api/payments  status_code=500    0.044
  endpoint=/api/payments/INVALID-999  status_code=404    0.355
```

- `status_code=~"5.."` is a **regex label matcher** — matches 500, 502, 503, 504 in one expression
- Dividing errors by total gives the error ratio; ×100 for percentage

> *Say: "Our SLO target is 99.9% — that's 0.1% max error rate. The `=~` operator is Prometheus regex matching. If this stays above 0.1% for 2 minutes, PaymentErrorRateHigh fires and pages the on-call."*

---

**Query 3 — Latency: p99 and p50 per endpoint**

*Grafana UI — paste Query A in Code mode, click `+ Add query` for Query B:*
```promql
# Query A — p99
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{job="tch-payment-app"}[1m])) by (le, endpoint)
)

# Query B — p50 (add as second query to overlay on the same graph)
histogram_quantile(0.50,
  sum(rate(http_request_duration_seconds_bucket{job="tch-payment-app"}[1m])) by (le, endpoint)
)
```

*Bash:*
```bash
bash observability/promql.sh --latency
```
```
━━━ LATENCY — p99 per endpoint (seconds)
  endpoint=/api/transactions   0.845   ← 5% slow-path kicking in
  endpoint=/api/payments       0.247
  endpoint=/api/settlements    0.097

━━━ LATENCY — p50 per endpoint (seconds)
  endpoint=/api/transactions   0.064   ← p50 is fine; p99 is not
  endpoint=/api/payments       0.113
  endpoint=/api/settlements    0.037
```

- `_bucket` metric records how many requests fell into each pre-defined latency band
- `by (le, endpoint)` — `le` = "less than or equal to", the bucket boundary; required for histogram_quantile
- The gap between p99 and p50 is the tail latency story

> *Say: "histogram_quantile is the standard Prometheus pattern for percentiles. The gap between p50 and p99 shows tail latency — p99 of 845ms while p50 is 64ms means a small slice of customers wait 13× longer. Averages completely hide this."*

---

**Query 4 — Saturation: in-flight requests**

*Grafana UI — paste in Code mode, then change visualization to **Stat** for a big live number:*
```promql
http_requests_in_flight{job="tch-payment-app"}
```

*Bash:*
```bash
bash observability/promql.sh --saturation
```
```
━━━ SATURATION — In-flight requests
  instance=app:8080  job=tch-payment-app    2.000
```

> *Say: "Saturation is the hardest golden signal because it's service-specific. In-flight requests is a leading indicator — when this climbs, latency follows seconds later. We alert at 50 to scale out before customers feel degradation."*

---

**Query 5 — SLO burn rate**

*Grafana UI — paste in Code mode:*
```promql
(
  1 - (
    sum(rate(http_requests_total{job="tch-payment-app",status_code=~"5.."}[1h]))
    /
    sum(rate(http_requests_total{job="tch-payment-app"}[1h]))
  )
) * 100
```

*Bash:*
```bash
bash observability/promql.sh --slo
```
```
━━━ SLO — Success rate % over 1h (target ≥ 99.9%)
  (all)                        99.619

━━━ SLO — Payment errors by type (rate/s)
  error_type=db_timeout        0.044
  error_type=invalid_id        0.355
```

> *Say: "If this reads 99.5%, we've burned 5× our daily error budget in one hour — at that rate the monthly budget exhausts in 6 hours. That triggers a deploy freeze. We run a 1h window for fast-burn detection and a 30d window for monthly stakeholder reporting."*

---

**Query 6 — Custom query (any PromQL expression)**

*Bash — run any expression directly:*
```bash
bash observability/promql.sh --query 'rate(http_requests_total{job="tch-payment-app"}[30s])'
```

> *Say: "In production I query Prometheus directly from bash in runbooks and incident scripts. When a page fires at 3am I don't want to open a browser — I run the script and see numbers immediately."*

---

#### 3c. View active alerts in Alertmanager

1. Open **http://localhost:9093**
2. Firing alerts appear here with their labels, severity, and annotations

To see all alert rules and their current state in Prometheus:
1. Open **http://localhost:9090/alerts**
2. You'll see all 5 rules: `PaymentLatencyHigh`, `PaymentErrorRateHigh`, `SLOErrorBudgetBurning`, `PaymentTrafficAnomaly`, `PaymentServiceSaturated`
3. Click any rule name to expand its current evaluation result

> *Say: "Alert rules live in `observability/prometheus/alerts.yml` — version-controlled and reviewed in PRs like any other code. In production these route to PagerDuty for the payment on-call and Slack for the engineering channel. The `runbook` annotation in each alert links directly to the remediation playbook so the responder doesn't waste time searching."*

---

### Step 4 — Vault: secret management demo

From the repo root:

```bash
bash k8s/vault/dev_mode.sh
```

This runs three segments inside the Vault container (no host `vault` CLI needed):

**Segment 1 — KV secrets:**
```
Reading full secret:
  api_key        tch-api-key-abc123
  db_password    super-secret-prod-pw
  jwt_secret     jwt-signing-key-xyz
```

**Segment 2 — Dynamic PostgreSQL credentials:**
```
Credential #1:  username=v-token-payment--UGxAD...  password=...  (expires 1h)
Credential #2:  username=v-token-payment--ZNRma...  password=...  (different username)
```

**What to say:** *"Each pod gets a unique rotating credential with a 1-hour TTL. No static passwords in env vars, Helm values, or ConfigMaps. In Kubernetes, the Vault Agent Injector reads pod annotations and writes secrets to a tmpfs volume — they never touch disk. Revoke one without affecting others. Every read is in the audit log — that's how we satisfy SOC 2 access control requirements."*

See `k8s/vault/annotated-deployment.yaml` for the K8s sidecar injection pattern.

---

### Step 5 — OPA Gatekeeper: Policy as Code

From the repo root:

```bash
bash k8s/apply_and_test.sh
```

This:
1. Installs OPA Gatekeeper into the OrbStack cluster
2. Applies the `payment-app` namespace with `pod-security.kubernetes.io/enforce: restricted`
3. Applies a `ConstraintTemplate` + `Constraint` that blocks privileged containers
4. Attempts to launch a privileged pod — **expects a rejection**

Expected output:
```
PASS — privileged pod was rejected by Gatekeeper.
```

**What to say:** *"The policy is a 15-line Rego file checked into git — version-controlled, peer-reviewed, enforced at admission time. No pod can bypass it by editing a config. This is how we implement Policy as Code for SOC 2 and PCI-DSS: the constraint IS the audit evidence."*

---

### Step 6 — Deploy payment app to K8s

```bash
# Build the image (OrbStack K8s shares the Docker daemon — no push needed)
docker build -t tch-payment-app:local app/

# Deploy
kubectl apply -f k8s/app/payment-deployment.yaml

# Verify
kubectl get pods -n payment-app
kubectl get hpa -n payment-app
```

Pods start in ~15s. Key hardening in the manifest:

```yaml
runAsNonRoot: true          # no root containers
runAsUser: 1001             # numeric UID (K8s verifiable)
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]             # stripped down to zero Linux capabilities
```

**HPA:** scales 2→8 replicas at 60% CPU — handles payment volume spikes without manual intervention.

---

### Step 7 — ELK: log search in Kibana

1. Open **http://localhost:5601**
2. Go to **Discover** → create index pattern `filebeat-practice-*`
3. The payment service writes structured JSON logs (event, payment_id, amount, status)

**What to say:** *"The payment service logs to structured JSON via structlog — every transaction has a payment_id field so we can trace a single payment across all log lines. Filebeat ships them to Elasticsearch. In production we'd add Logstash for parsing and enrichment. This gives compliance teams a full audit trail: who authorized, what amount, what outcome."*

---

### Step 8 — SonarQube SAST scan (local)

Run a real static analysis scan against the payment service:

```bash
# From repo root — starts SonarQube + Postgres, then scans app/
bash sonarqube/scan.sh
```

First run takes ~2 minutes (SonarQube DB initialisation). Subsequent runs ~20s.

The scan prints a direct link when it finishes:
```
✓ Quality Gate: OK
Results  → http://localhost:9000/dashboard?id=tch-payment-app
Login    → admin / admin
```

**Click that URL directly** — it takes you straight to the project dashboard. No navigation needed.

If you're already in the SonarQube UI and need to get back:
1. Open **http://localhost:9000**
2. Log in: `admin` / `admin`
3. The home page shows **"TCH Payment Service"** as a card — click it
4. If the home page is empty, click **Projects** in the top navigation bar → the project appears there

---

#### What you'll see on the project dashboard

The dashboard is divided into two columns — **Reliability**, **Security**, and **Maintainability**:

| Metric | What it means | Current result |
|--------|--------------|----------------|
| **Bugs** | Logic errors likely to cause wrong behaviour | 0 |
| **Vulnerabilities** | Confirmed security issues | 0 |
| **Security Hotspots** | Code that needs manual security review | 4 |
| **Code Smells** | Maintainability issues (tech debt) | 1 |
| **Coverage** | % of lines covered by tests | 0.0% (no tests yet) |
| **Duplications** | Copy-pasted code blocks | 0.0% |

**Navigate the dashboard:**
- Click **Security Hotspots** → see the 4 flagged locations, click each to read the review question (e.g. "Make sure this random value is cryptographically secure")
- Click **Code Smells** → see the 1 issue, its location, and the remediation effort estimate
- Click **Measures** tab (top of project page) → full breakdown of every metric category
- Click **Code** tab → file-by-file view with inline issue markers

---

**What to say:** *"SonarQube is the SAST gate in our pipeline — it catches security hotspots, hardcoded secrets, SQL injection patterns, and code smells before the image is ever built. The 4 security hotspots here are flagged for human review: they're not confirmed vulnerabilities but they require a developer to read and acknowledge them. The Quality Gate is configured to fail the pipeline if new Blocker issues are introduced or coverage drops below threshold — that's `sonar.qualitygate.wait=true` in the GitHub Actions job. Every PR gets gated before it can merge."*

**Native arm64 scanner (faster):**
```bash
brew install sonar-scanner   # one-time, native M1 binary
bash sonarqube/scan.sh       # script auto-detects and uses it
```

---

### Step 9 — CI/CD pipeline reference

Point to `.github/workflows/secure-pipeline.yml` (**triggers on every push to main**). Walk through the 5 stages:

```
commit → lint + pytest → SAST (Bandit) ──┐→ deploy staging (stub)
                       → build + Trivy ──┘→ DAST (stub) → prod gate
```

**Key talking points:**
- Bandit SAST scans for security hotspots (medium+ severity) — no external token needed
- Trivy scans the container image for CRITICAL/HIGH CVEs; set `exit-code: 1` to block on them in a real engagement (report-only here so the demo stays green with OS-level CVEs from the base image)
- DAST stub shows where OWASP ZAP would scan staging — finds runtime vulns static analysis misses
- ArgoCD pulls from git (GitOps) — git IS the audit trail for every deployment
- Manual approval gate before prod — uncomment `environment: production` in the workflow and add a required reviewer in GitHub Settings → Environments

**Jenkins equivalent:** `Jenkinsfile` at repo root.

---

### Step 10 — Shut down everything

```bash
cd devops-tch-practice
bash shutdown.sh
```

Stops in order:
1. Background traffic script
2. All Docker Compose containers
3. `payment-app` and `gatekeeper-system` K8s namespaces (waits for full pod termination)
4. Local Docker image

Prints `(none — all clean)` when `docker ps` has nothing left except OrbStack's own system pods.

---
