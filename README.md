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

| Panel | Golden Signal | What to say in the interview |
|-------|--------------|------------------------------|
| Payment Request Rate | Traffic | "We alert when rate is 2× the 30-min baseline — catches DDoS and viral spikes before customers feel it" |
| 5xx Error Rate | Errors | "SLO is 99.9% success rate. Alert fires at >0.1% error rate sustained for 2 minutes" |
| p99 & p50 Latency | Latency | "The 5% slow-path in the app drives p99 tail latency. Alert fires when p99 exceeds 500ms" |
| In-flight Requests | Saturation | "4th golden signal — shows queue depth before the service saturates. Alert at >50 in-flight" |
| Payment Errors by Type | Business | "Beyond the four signals we track domain errors: db_timeout, invalid_id — bridges ops and product" |
| Payment Amount Distribution | Business | "p99 transaction size is a fraud signal — sudden spike in large amounts at 3am is an anomaly" |

---

#### 3b. Run PromQL queries live in Explore

This is where you demonstrate hands-on depth. The interviewer sees you write and interpret queries in real time.

**How to open Explore:**
1. Click **☰** (hamburger) → **Explore** (compass icon)
2. Confirm the datasource at the top reads **Prometheus**
3. Paste each query into the query box → press **Shift+Enter** or click **Run query**
4. Use the **time range picker** (top right) and set it to **Last 15 minutes** for best visibility

---

**Query 1 — Traffic: request rate per endpoint**
```promql
sum(rate(http_requests_total{job="tch-payment-app"}[1m])) by (endpoint)
```
Returns requests-per-second broken out by endpoint as separate lines on the graph.

- `rate()` computes per-second average over the time window
- `[1m]` = 1-minute window — fast response for incident detection
- `by (endpoint)` = split the result by the endpoint label

> *Say: "This is the traffic golden signal. The [1m] window gives fast-moving data for real-time incident response. In alert rules I use [5m] to avoid noise from brief spikes. A sudden drop to zero on /api/payments is the first sign of an outage."*

---

**Query 2 — Errors: 5xx error rate as a percentage**
```promql
sum(rate(http_requests_total{job="tch-payment-app",status_code=~"5.."}[1m]))
/
sum(rate(http_requests_total{job="tch-payment-app"}[1m]))
* 100
```
Returns a single number: the percentage of requests returning 5xx errors (e.g. `1.5` = 1.5%).

- `status_code=~"5.."` is a **regex label matcher** — matches 500, 502, 503, 504, etc.
- Dividing errors by total gives the error ratio; multiply by 100 for percentage

> *Say: "Our SLO target is 99.9% success — that's 0.1% max error rate. The `=~` operator is Prometheus regex matching on label values. If this stays above 0.1% for 2 minutes, the PaymentErrorRateHigh alert fires and pages the on-call."*

---

**Query 3 — Latency: p99 per endpoint**
```promql
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{job="tch-payment-app"}[1m])) by (le, endpoint)
)
```
Returns p99 latency in seconds for each endpoint.

- `_bucket` is the histogram metric — it records how many requests fell into each latency band
- `by (le, endpoint)` — `le` means "less than or equal to", the bucket boundary label; required for histogram_quantile
- Change `0.99` → `0.50` for median latency

**To show p99 and p50 on the same graph:** click **+ Add query** and paste:
```promql
histogram_quantile(0.50,
  sum(rate(http_request_duration_seconds_bucket{job="tch-payment-app"}[1m])) by (le, endpoint)
)
```

> *Say: "histogram_quantile is the standard Prometheus pattern for computing percentiles. The gap between p50 and p99 shows tail latency — in a payment system a p99 of 800ms while p50 is 50ms means a small percentage of customers are waiting 16× longer. That's what we alert on, not the average."*

---

**Query 4 — Saturation: in-flight requests**
```promql
http_requests_in_flight{job="tch-payment-app"}
```
A simple Gauge — the number of requests currently being processed right now.

To see it as a large number instead of a graph: click the **visualization type dropdown** (top left of the panel in Explore) → select **Stat**.

> *Say: "Saturation is the hardest golden signal to measure because it's service-specific. In-flight requests is a leading indicator — when this climbs, latency follows seconds later. We alert at 50 in-flight to scale out before customers see degradation."*

---

**Query 5 — SLO burn rate: is the error budget burning too fast?**
```promql
(
  1 - (
    sum(rate(http_requests_total{job="tch-payment-app",status_code=~"5.."}[1h]))
    /
    sum(rate(http_requests_total{job="tch-payment-app"}[1h]))
  )
) * 100
```
Returns the success rate % over the past hour (target: ≥ 99.9%).

> *Say: "This is the SLO burn rate query. If I see 99.85% here, we've burned 15% of the month's error budget in one hour — at that rate the budget exhausts in 7 hours, not 30 days. That's the signal to freeze risky deploys and focus the team on reliability. We run this query on a 1h window for fast burn detection, and a 30d window for monthly budget reporting to stakeholders."*

---

**Query 6 — Business metric: payment error breakdown**
```promql
sum(rate(payment_errors_total{job="tch-payment-app"}[1m])) by (error_type)
```
Returns per-second rate of payment-specific errors broken out by type (db_timeout, invalid_id).

> *Say: "Beyond the four golden signals, we instrument business-level metrics using custom counters. A spike in db_timeout errors at 2am points to a database issue. A spike in invalid_id errors might mean a broken client — neither would surface clearly in a generic 5xx error rate because they get averaged in. These domain-specific metrics are how SRE bridges ops and the product team."*

---

**Query 7 — Node-level saturation: CPU idle %**
```promql
100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)
```
Returns CPU utilization % from node-exporter (the host running all the containers).

> *Say: "This is system-level saturation from node-exporter — independent of the application. We correlate this with in-flight request metrics to distinguish between 'the app is slow' and 'the host is overloaded'. In Kubernetes we'd use kube-state-metrics and container_cpu_usage_seconds_total instead."*

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

### Step 8 — CI/CD pipeline reference

Point to `.github/workflows/secure-pipeline.yml`. Walk through the 6 stages:

```
commit → lint/test → SAST (SonarQube) → build + Trivy scan → deploy staging
       → DAST (OWASP ZAP) → manual approval gate → promote to prod
```

**Key talking points:**
- Trivy exits with code 1 on CRITICAL CVE — **blocks the pipeline**
- DAST runs against staging, not prod — finds runtime vulns static analysis misses
- ArgoCD pulls from git (GitOps) — git IS the audit trail for every deployment
- Manual approval gate before prod — CAB process codified into the pipeline

**Jenkins equivalent:** `Jenkinsfile` at repo root.

---

### Step 9 — Shut down everything

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
