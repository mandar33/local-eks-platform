# Future improvements and known gaps

A list to pick from, roughly in order of value. Nothing here is broken today; these are the places where the local setup is simpler than it should be, or hasn't been tested.

## Not yet tested

- **A clean rebuild from an empty laptop.** The clusters were built step by step, and fixes found along the way went into README "Setup from scratch", but nobody has followed those steps from start to finish on a fresh machine. To test: stop region B (frees about 3 GB), create a third kind cluster, follow the setup exactly, and note every deviation. Expect small ordering issues (for example apps waiting for Vault or the registry, which is by design).
- **Running for weeks.** Behaviour over the 30-day CI token lifetime, the 24-hour maximum DB lease, and certificate renewal has only been reasoned about, not observed.

## Resilience

- **Rolling-update hardening:** `maxUnavailable: 0`, `maxSurge: 1`, `minReplicas: 2`, a PodDisruptionBudget, and a short `preStop` sleep so Envoy stops sending traffic before a pod exits. Needed anyway on EKS Auto Mode, which replaces nodes regularly (see `eks-auto-mode.md`).
- **Readiness that means something:** `/healthz` doesn't check Flipt, crud-api or the database, so a release that starts but returns errors rolls out fully.
- **Automatic rollback:** Argo Rollouts is installed but unused. An analysis step (error rate from Istio metrics) could stop and roll back a bad canary on its own.
- **Data per cell and per region:** cells share one Postgres, and region B reads region A's. A database problem hits everything. Each cell (and region) should have its own data, with replication between regions.
- **Istio multi-cluster:** failover is per region (global load balancer). Connecting the meshes would let single services fail over.
- **Vault Secrets Operator renewal:** after a restart it renewed a lease only one minute before expiry. Consider a shorter `renewalPercent`, alerts on lease age, or a longer DB TTL.

## Security

- **Private repository**, with a read-only token for Argo CD and Flipt from Vault (designed, not done).
- **Vault:** auto-unseal with a KMS, HA with Raft storage, retire the root token, TLS on the listener.
- **Registry:** require login to pull (`imagePullSecrets` from Vault), and let Kargo trust the registry CA instead of `insecureSkipTLSVerify`.
- **Image signing** (cosign or Notation) in CI, and signature checks in Zot or an admission controller.
- **Gateway TLS:** serve HTTPS with a cert-manager certificate.
- **Pin `actions/checkout` and base images** already pinned; keep them updated with Dependabot or Renovate.

## Delivery

- **Kargo for crud-api too:** today only frontend-api is promoted by Kargo; crud-api's tag is edited by hand.
- **Auto-promotion to dev:** let Kargo promote to dev automatically after CI, and keep the manual approval for region B.
- **Health check for `Cell` in Argo CD** (Lua in `argocd-cm`), so a stuck cell shows as Degraded instead of Healthy.
- **Cell router from data:** routes are hand-written in a VirtualService; real cell routers look users up in a table.
- **`crossplane beta trace`** in the cells lab for debugging stuck cells.

## Docs

- Screenshots of the Argo CD, Kargo and Zot UIs in the guide.
- A glossary page linking every term to the lab that introduces it.
