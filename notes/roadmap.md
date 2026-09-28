# Roadmap: what's done, what's next

One place to see where things stand. Updated as work happens. Details for each platform item are in [future-improvements.md](future-improvements.md); problems hit along the way are in [findings.md](findings.md).

Status: ✅ done · 🔜 next · ⏳ waiting on a decision · ⬜ later

## Hands-on exercises

| # | Exercise | Status | Notes |
|---|---|---|---|
| 1 | Morning start-up: bring the platform back after a restart | ✅ 27 Sep | Unsealed Vault, all green |
| 2 | Turn a feature off and on with a Git commit | ✅ 27 Sep | Region B lagged a few seconds (its own Flipt) |
| 3 | Ship a code change: commit → CI → approve → running | ✅ 28 Sep | Round 2: CI run 7, `1.2.7` |
| 4 | Release to the second region | ✅ 28 Sep | Round 2, Kargo promotion to `region-b` |
| – | Upgrade the cells by hand | ✅ 27 Sep | `1.1.1` → `1.2.6`, then `1.2.7` in Round 2 |
| – | Incident: cell B `500` after an upgrade | ✅ 28 Sep | Stale DB login; fixed by deleting the Secret |
| 5 | Change configuration without changing code (Helm values) | 🔜 | For example `minReplicas`, an env var |
| 6 | Break something by hand; watch Argo CD repair it | ⬜ | |
| 7 | A bad release: roll back to the previous version | ⬜ | Now via `promote.sh` with the older version |
| 8 | Canary release: 10% of users to a new version | ⬜ | Two commits: pods first, then weights |
| 9 | Add and remove a route; see who may call whom | ⬜ | |
| 10 | Add a new cell, then survive losing a region | ⬜ | |
| – | Round 3: try the new Kargo flow (`1.2.9` through all four stages) | ⬜ | After the docs update |
| – | Final: restructure into dev → staging → prod | 🔜 | Design ready: [environments-design.md](environments-design.md), 10 phases |

## Snyk track (prep for work training)

Four Snyk products, each tried on this repo. Run the scan, read the results, fix one thing, then add the scan to CI.

| # | Step | Status | Notes |
|---|---|---|---|
| S1 | Account + import the GitHub repo in the Snyk web UI | ⬜ | Nothing installed locally; Snyk scans from GitHub. CLI only if needed later |
| S2 | Open Source (SCA): `snyk test` on `apps/*/requirements.txt` | ⬜ | Vulnerable Python packages; upgrade paths |
| S3 | Container: `snyk container test` on both app images | ⬜ | Compare with the 71 → 0 CVE hardening; base image advice |
| S4 | IaC: `snyk iac test` on Helm charts / manifests | ⬜ | Missing limits, privileged pods, etc. Links to Group 2 resilience |
| S5 | Code (SAST): `snyk code test` on `apps/` | ⬜ | Must be enabled in the Snyk org settings first |
| S6 | Ignore vs fix: `.snyk` policy file, severity thresholds | ⬜ | `--severity-threshold=high`; why ignores need a reason and expiry |
| S7 | Snyk in CI: GitHub Actions step that fails the build on high | ⬜ | `SNYK_TOKEN` from Vault; links to Group 2 "Tests and lint in CI" |
| S8 | `snyk monitor` + the web UI: projects, reports, fix PRs | ⬜ | What the work training will likely show |

## Platform work

### Group 1: finish what's in flight

| Item | Status | Notes |
|---|---|---|
| Kargo manages both apps and the cells (`dev` → `region-b` → `cell-a` → `cell-b`), `scripts/promote.sh` | ✅ 28 Sep | Commit `842bde6`, tested with `1.2.8` in every copy |
| Update the guide and README for the new Kargo flow | 🔜 | They still describe hand-edited crud-api and cells |
| Automatic check for stale DB logins | 🔜 | Hit cell B and region B after restarts |
| Helper CLI replacing `promote.sh`, `flag.sh`, `check-expiry.sh` | ⏳ | Python (recommended) or Go |

### Group 2: gaps every real platform fills

| Item | Status | Why |
|---|---|---|
| Observability: Prometheus, Grafana, Kiali, Loki | ⬜ | Biggest gap: see traffic, errors and latency instead of reading logs |
| Tests and lint in CI | ⬜ | Stop broken code before it's packaged |
| Resilience: 2 replicas, PodDisruptionBudgets, memory limits, graceful shutdown | ⬜ | Needed for real traffic and for EKS |
| Backups and a practised restore (Postgres, Vault) | ⬜ | Losing the cluster currently loses the data |

### Group 3: architecture

| Item | Status |
|---|---|
| dev → staging → prod restructure, profiles `bigtech` (cells, waves) / `small` ([design](environments-design.md)) | 🔜 phases 1–4 done 28 Sep (folders, app of apps, chart extras, dev namespace); phase 5 (staging + a database per env) next |
| Automatic promotion with health checks and bake times (Argo Rollouts analysis) | ⬜ |
| Real cell router (tenant → cell lookup, verified token) and a database per cell | ⬜ |
| Istio multi-cluster | ⬜ |
| Promote flag changes region by region | ⬜ |

### Group 4: security

| Item | Status |
|---|---|
| Private repo with read-only tokens for Argo CD and Flipt | ⬜ |
| Policies (Kyverno): refuse unsafe deployments | ⬜ |
| NetworkPolicies under Istio's rules | ⬜ |
| Image signing and SBOM (cosign) | ⬜ |
| Vault: auto-unseal, HA, no root token | ⬜ |

### Group 5: operations

| Item | Status |
|---|---|
| Remaining hand-installed pieces under Argo CD (Istio, cert-manager, Vault, Kargo, Crossplane) | ⬜ |
| Chaos drills: break things on purpose, check recovery | ⬜ |
| Clean rebuild from an empty laptop | ⬜ |

## Dates to remember

| Date | What |
|---|---|
| 26 Oct 2026 | CI runner's Vault token expires → `scripts/setup-ci.sh runner` |
| 25 Dec 2026 | Kargo's GitHub token expires → new token, `scripts/set-kargo-git-token.sh` |

## Recently done

| Date | What | Commit |
|---|---|---|
| 28 Sep | Phase 4: dev apps in namespace `dev` (Vault role `crud-api-dev`, access rule from the chart), `dev.localhost:8080`; ~6 min of 503 from a misplaced DestinationRule (findings) | `2955ae1`, `dd53162` |
| 28 Sep | Phase 3: `base-api` 0.2.0 with optional Vault DB credentials, AuthorizationPolicy, PDB (off by default; renders unchanged) | – |
| 28 Sep | Phase 2: `root` app of apps; app lists now come from Git, only `root.yaml` is applied by hand | – |
| 28 Sep | Phase 1: `apps/common` + per-copy values, `platform/region-a` and `region-b`, `argocd/`; renders identical, all apps green | `7899393` + next |
| 28 Sep | Environments design: profiles `bigtech` / `small`, cells via ApplicationSet | `ca1da6e` |
| 28 Sep | Kargo for both apps and the cells; `promote.sh`; CI promotes the version pair | `842bde6` |
| 28 Sep | Incident notes: stale DB login after restart | `56d1aae` |
| 27 Sep | Flipt managed by Argo CD in both regions | `a7b0c93` |
| 27 Sep | Repo tour in the guide; renewal reminders; `check-expiry.sh` | – |
| 26 Sep | CI with GitHub Actions and a self-hosted runner; `azure-pipelines.yml` for comparison | `29f2ae7` |
| 26 Sep | Hardened images (71 → 0 known CVEs), canary, cells, second region | – |
