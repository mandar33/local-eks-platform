# Findings: what we learned building this

Everything below actually happened while building and testing this platform (25–26 Sep 2026). Each entry says what we saw, why it happened, and what fixed it. Most are now handled in the scripts or manifests; the last column says where.

## Local environment (laptop, Windows, Docker Desktop)

| What we saw | Why | Fix | Where it's handled now |
|---|---|---|---|
| `x509: certificate signed by unknown authority` from kubectl, helm, istioctl and git | Norton Web Shield intercepts HTTPS, including to `127.0.0.1`, and re-signs it with its own certificate | Exclude those programs from HTTPS scanning. For git: `http.sslBackend=schannel`. Scripts accept a `KUBECTL` override that runs kubectl inside the kind node | README "Windows notes"; `scripts/lib.sh` |
| kind failed to start Kubernetes 1.36 | Docker Desktop's WSL2 kernel uses cgroup v1, which Kubernetes 1.35+ refuses | Pin Kubernetes 1.34 in the kind configs | `kind-config*.yaml` |
| `KUBECTL="..." script.sh` "is not recognized as a cmdlet" | That's Bash syntax, typed into PowerShell | Use Git Bash, or set `$env:KUBECTL` first and call `bash.exe` | README "Windows notes" |
| Double quotes vanished when calling `bash.exe` from PowerShell | Windows PowerShell 5.1 strips embedded double quotes when calling native programs | Avoid inner double quotes; set variables in PowerShell first | README "Windows notes" |
| `docker cp` and `docker exec mkdir /etc/...` failed from Git Bash | Git Bash rewrites `/unix/paths`; with that turned off, Docker for Windows then gets `/c/...` paths | `MSYS_NO_PATHCONV=1` plus `cygpath -w` for host paths | `scripts/lib.sh`, `setup-region.sh`, `setup-ci.sh` |
| A Kargo GitHub token of 279 characters | Pasted three times at a hidden prompt (nothing is shown while pasting) | The script now rejects anything that isn't exactly one GitHub token | `scripts/set-kargo-git-token.sh` |
| `kubectl` resolved to Docker Desktop's copy, `istioctl` to an old 1.22 | The system PATH comes before the user PATH on Windows | Renamed the old `istioctl.exe`; Docker's kubectl 1.36 is fine | — |

## Kubernetes, GitOps and releases

| What we saw | Why | Fix | Where |
|---|---|---|---|
| `argocd-applicationset-controller` crash-looping | Argo CD installed with client-side apply; the ApplicationSet CRD is too large for it | `kubectl apply --server-side --force-conflicts` | README setup step 3 |
| Flipt crash-looping after a push | `features.yaml` used `state: ENABLED`, a field Flipt v1 doesn't accept | Use `enabled: true`; Flipt's log names the bad line | Lab 5 |
| Argo CD sync failed: `field is immutable` | Adding a label (`track`) to a Deployment's selector | Delete the Deployment once; Argo CD recreates it (seconds of downtime) | Troubleshooting |
| Disabled canary kept running, app `OutOfSync` | Argo CD refuses to auto-sync an app down to zero resources | `allowEmpty: true` on that app | `argocd-apps.yaml` |
| Canary weights `100`/`0` became `00`/`0` | A careless find-and-replace (`10` → `0` also matched inside `100`) | Fixed within a minute; always check the diff | Lab 11 note |
| 7 × `503` while turning the canary on | Pods and weights in one commit: Argo CD applied the weights before the canary pods existed | Two commits: pods first, then weights (reverse to turn off). 0 errors in 267 requests | Lab 11 |
| App `Degraded` for about a minute after every rollout | The new pod has no CPU numbers yet, so its HPA can't report | Wait; clears by itself. Kargo shows the Stage `Unhealthy` meanwhile | Troubleshooting |
| A `git revert` rollback wasn't reflected in Kargo | Kargo tracks what it promoted, not hand-made Git changes | Roll back by promoting older Freight in Kargo | Lab 6 |
| Argo CD took about 80–130 s to apply a push | Its regular check of Git runs every few minutes | `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=normal --overwrite`: about 3 s | Lab 6 |
| A change to `frontend-values.yaml` also changed the cells and region B | They all reuse that values file | Expected; per-environment overrides go in their own files | Lab 6 |
| Crossplane `Cell` stayed `READY False` | Argo CD Applications and AuthorizationPolicies have no `Ready` condition | The Composition sets readiness from Argo CD health | `crossplane/cell-api.yaml` |

## Secrets, registry, apps

| What we saw | Why | Fix | Where |
|---|---|---|---|
| A password in a public repo's history | An early manifest had a plain-text dev password | History rewritten, password rotated, Vault now issues all DB credentials | README "Secrets" |
| crud-api `password authentication failed` hours after a Vault restart test | The Vault Secrets Operator lost its Vault login while Vault was sealed and quietly stopped renewing; the 1-hour DB user expired | `bootstrap-vault.sh unseal` now restarts the operator | `scripts/bootstrap-vault.sh` |
| The operator renewed a lease only 1 minute before expiry after a restart | Renewal timing restarts with the operator | It did renew; worth watching (see future improvements) | — |
| `docker push` to Zot: `manifest invalid` (HTTP 415) | Zot accepts only OCI manifests by default; `docker push` sends Docker v2 ones | `"compat": ["docker2s2"]` in Zot's config | `registry/zot.yaml` |
| Hardened image still showed 3 CVEs | pip (with vendored setuptools/msgpack) was copied into the runtime image | Uninstall pip after installing dependencies: 71 → 0 known CVEs | `apps/*/Dockerfile` |
| One `500` after the app sat idle | crud-api reused a DB connection the Istio sidecar had closed | `pool_pre_ping=True` (shipped through CI as 1.2.2) | `apps/crud-api/main.py` |
| `kubectl exec ... sh` fails in app containers | The Chainguard runtime image has no shell, on purpose | Use logs, or `kubectl debug` | README "Hardened images" |
| `docker cp` into the CI runner made unreadable files | `docker cp` creates root-owned files | Write credentials through `docker exec -i` as the runner user | `scripts/setup-ci.sh` |
| Files copied from Windows into an image weren't executable | No Unix execute bit on Windows | `ENTRYPOINT ["bash", "script.sh"]` | `platform/github-runner/Dockerfile` |

## Measured behaviour (for reference)

| Thing | Measured |
|---|---|
| Flipt picks up a flag change from Git | 17 s (region A); region B a few seconds later |
| Argo CD applies a Git change without / with refresh | 80–130 s / about 3 s |
| Argo CD self-heal of a deleted Service | about 1 s |
| HPA scale-out under load (1 → 3 pods) | about 40 s |
| Rolling restart of both apps under load | 259/259 requests OK |
| Broken image rolled out | old pod kept serving: 151/151 requests OK |
| Region A gateway down, global load balancer | 176/176 requests OK |
| CI build + scan of both images | about 2 min |
| New cell ready / removed cell cleaned up | 65 s / 16 s |
| Known CVEs, `python:3.13-slim` vs Chainguard | 71 (10 high) vs 0 |
