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
| – | Final: restructure into dev → staging → prod | ⬜ | Agreed layout in future-improvements |

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
| dev → staging → prod restructure, `<what>-<env>-<region>` naming | ⬜ (planned as the final exercise) |
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
| 28 Sep | Kargo for both apps and the cells; `promote.sh`; CI promotes the version pair | `842bde6` |
| 28 Sep | Incident notes: stale DB login after restart | `56d1aae` |
| 27 Sep | Flipt managed by Argo CD in both regions | `a7b0c93` |
| 27 Sep | Repo tour in the guide; renewal reminders; `check-expiry.sh` | – |
| 26 Sep | CI with GitHub Actions and a self-hosted runner; `azure-pipelines.yml` for comparison | `29f2ae7` |
| 26 Sep | Hardened images (71 → 0 known CVEs), canary, cells, second region | – |
