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
| – | Round 3: a release through `dev → staging (automatic) → prod-a1 → prod-a2 → prod-b1` | 🔜 | Docs are updated. Also the first real test of automatic staging and of the walkthrough in the guide |
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
| dev → staging → prod restructure, profiles `bigtech` (cells, waves) / `small` ([design](environments-design.md)) | 🔜 phases 1–9 done 28 Sep (… profiles `bigtech` / `small`, guardrails); phase 10 (docs) next |
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
| 28 Sep | Docs: README rewritten for the new layout; HTML guide updated (local only) incl. Lab 12 cells/waves, new Lab 14 profiles, layout and ApplicationSet diagrams. Flag 50% split re-measured in Flipt namespace `dev`: same users as before, prod untouched. Automatic staging still untested: first real run is Round 3 | `c2b9a75`, `18b5764`, `94d294e` |
| 28 Sep | Phase 9: Argo CD projects `nonprod` / `prod` (tested: a nonprod app aimed at `prod-a1` is refused); staging auto-promotes once dev verifies (untested until the next release, Round 3); Flipt namespaces `dev` / `staging` / `prod`, `FLIPT_NAMESPACE` per frontend, `flag.sh` per namespace. 0 failed of 90 requests | `cd8c972`, `ed042c1` + next |
| 28 Sep | Phase 8: profiles `bigtech` / `small` (`k8s-manifests/profiles/`), switched by `scripts/profile.sh` (one Git line + global-lb config). Tested both ways: prod back in ~20 s (small) and ~13 s (bigtech), 1 failed check on `:9080` during the first switch. Memory: small ≈ 8.3 GB, bigtech ≈ 8.7 GB | `ed514ec` … `f373fa7` |
| 28 Sep | Phase 7 waves proven: `prod-a2` promoted itself 13 min after `prod-a1`, `prod-b1` 11 min later; 315 requests, 0 failed | – |
| 28 Sep | Phase 7: prod cells `prod-a1`, `prod-a2` (region A), `prod-b1` (region B) via ApplicationSet, each with its own database; `localhost:8080` = cell router (odd/even users); Kargo waves `staging → prod-a1 → (10 min) → prod-a2 → (10 min) → prod-b1`, later waves automatic; old cells, region B's `default` apps and Crossplane removed with 0 failed requests | `d351277` … `faef6b0` |
| 28 Sep | Phase 6: region B's own Postgres (`region-b-postgres`, `setup-region.sh database`); Vault reaches it on NodePort 30432; region A's Postgres NodePort removed. No downtime | `c7c539c`, `ee64077` + next |
| 28 Sep | Phase 5: staging (`staging.localhost:8080`, Kargo `dev → staging → region-b`), databases `crud_dev` / `crud_staging` each with its own Vault connection and role (`bootstrap-vault.sh databases`); ~8 min dev `500` from two operator surprises (findings) | `7adefd4` |
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
