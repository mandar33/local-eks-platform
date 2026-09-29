# GitOps labs: from reading Git to running prod from it

Twenty labs that build on each other, plus the end-to-end release test (Round 3) that everything else leans on. The component labs in the HTML guide (Labs 0–14) show what each tool *is*; these show how to *work* the GitOps way: every change is a commit, the cluster follows, and Git answers "what runs where, and why".

Labs 1–10 are the day-to-day of running a GitOps platform. Labs 11–20 go deeper: hooks, diff tuning, secrets, pull requests, automatic verification, losing the control plane, and finally rebuilding the whole platform from Git.

Status is tracked in [roadmap.md](roadmap.md).

| # | Lab | You'll be able to… | Time |
|---|---|---|---|
| R3 | [End to end: code → CI → dev → staging → prod waves](#r3-end-to-end-code--ci--dev--staging--prod-waves) | Ship a release to every prod cell and prove nobody noticed | 60 min (mostly waiting) |
| 1 | [Trace the desired state](#lab-1-trace-the-desired-state) | Point from any running pod to the exact lines in Git that made it | 20 min |
| 2 | [Drift: what Argo CD fixes, and what it doesn't](#lab-2-drift-what-argo-cd-fixes-and-what-it-doesnt) | Predict what happens to a hand-made change | 20 min |
| 3 | [Change one environment, predict the diff first](#lab-3-change-one-environment-predict-the-diff-first) | Know the blast radius of a commit before pushing it | 25 min |
| 4 | [Add and remove resources: prune, finalizers, order](#lab-4-add-and-remove-resources-prune-finalizers-order) | Create and delete things through Git only, in the right order | 30 min |
| 5 | [Promotion is a commit: gates and the audit trail](#lab-5-promotion-is-a-commit-gates-and-the-audit-trail) | Answer "when did 1.2.N reach prod-b1, and who moved it?" from Git | 25 min |
| 6 | [Stop a bad release: freeze the waves, roll back one cell](#lab-6-stop-a-bad-release-freeze-the-waves-roll-back-one-cell) | Contain a bad version to one cell and undo it properly | 45 min |
| 7 | [Guardrails: projects and change freezes](#lab-7-guardrails-projects-and-change-freezes) | Make some mistakes impossible, not just unlikely | 30 min |
| 8 | [Fleets: a new cell from one list entry](#lab-8-fleets-a-new-cell-from-one-list-entry) | Stamp out and retire a whole copy of the stack | 45 min |
| 9 | [Broken Git: bad commits and how to read them](#lab-9-broken-git-bad-commits-and-how-to-read-them) | Diagnose a failed sync from its status, fix forward or revert | 30 min |
| 10 | [Capstone: rebuild from Git, then run a release alone](#lab-10-capstone-rebuild-from-git-then-run-a-release-alone) | Trust Git as the backup, and run a full release with a written record | 60 min |
| 11 | [Sync hooks: run a check as part of the deploy](#lab-11-sync-hooks-run-a-check-as-part-of-the-deploy) | Make a sync fail when the app doesn't answer | 40 min |
| 12 | [Tuning the diff: ignoreDifferences and server-side apply](#lab-12-tuning-the-diff-ignoredifferences-and-server-side-apply) | Stop false `OutOfSync` without hiding real drift | 30 min |
| 13 | [Flags as GitOps: release a behaviour, not a build](#lab-13-flags-as-gitops-release-a-behaviour-not-a-build) | Roll a flag out env by env and by percentage, all in Git | 30 min |
| 14 | [Secrets in a GitOps repo](#lab-14-secrets-in-a-gitops-repo) | Add a secret an app reads, rotate it, and never commit it | 40 min |
| 15 | [Pull requests: preview every change, protect main](#lab-15-pull-requests-preview-every-change-protect-main) | Review a rendered diff on a PR; make Kargo work with branch protection | 60 min |
| 16 | [Kargo verification: a smoke test gates the next stage](#lab-16-kargo-verification-a-smoke-test-gates-the-next-stage) | Stop a bad release in dev automatically | 45 min |
| 17 | [Progressive delivery with Argo Rollouts](#lab-17-progressive-delivery-with-argo-rollouts) | Canary that promotes or aborts itself from a metric | 60 min |
| 18 | [Lose the hub: when Argo CD itself is down](#lab-18-lose-the-hub-when-argo-cd-itself-is-down) | Know what keeps running, what stops, and how it catches up | 30 min |
| 19 | [Adopt the hand-installed pieces](#lab-19-adopt-the-hand-installed-pieces) | Bring a running tool under Argo CD without a restart | 45 min |
| 20 | [Final: the platform from an empty laptop](#lab-20-final-the-platform-from-an-empty-laptop) | Rebuild everything from Git and list every manual step left | half a day |

**Rules for every lab**

- Change the cluster **only through Git**, unless the lab says "by hand" (that's the point of the lab).
- `git pull` before every commit: Kargo pushes to `main` too.
- Stage files by name, never `git add -A`.
- Keep the traffic probe (below) running during anything that touches prod, and read it at the end. "It worked" means 0 failed requests.
- Norton blocks host kubectl? `export KUBECTL="docker exec -i dev-cluster-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf"` and use `$KUBECTL` wherever these notes say `kubectl`.

**Tools used everywhere**

```bash
# Traffic probe: one request per second to each prod cell, written to a file
probe() { while true; do
  for c in prod-a1 prod-a2; do curl -s -o /dev/null -w "%{http_code} $c\n" -H "x-cell: $c" localhost:8080/users/1; done
  curl -s -o /dev/null -w "%{http_code} prod-b1\n" localhost:9080/users/1
  sleep 1; done; }
probe > /tmp/probe.log &          # start;  later: sort /tmp/probe.log | uniq -c ; kill %1

# Which version answers where
versions() {
  for h in dev staging; do printf '%-8s ' $h; curl -s -o /dev/null -D - -H "Host: $h.localhost" localhost:8080/healthz | grep -i '^x-app-version'; done
  for c in prod-a1 prod-a2; do printf '%-8s ' $c; curl -s -o /dev/null -D - -H "x-cell: $c" localhost:8080/healthz | grep -i '^x-app-version'; done
  printf '%-8s ' prod-b1; curl -s -o /dev/null -D - localhost:9080/healthz | grep -i '^x-app-version'; }

# Make Argo CD look at Git now instead of in 2 minutes
refresh() { kubectl annotate application "$1" -n argocd argocd.argoproj.io/refresh=normal --overwrite; }
```

---

## R3. End to end: code → CI → dev → staging → prod waves

The release path nobody has run in one go since the restructure. It's also the **first real test of automatic staging**.

```text
push apps/ ─► CI builds 1.2.N, scans ─► you Approve ─► Kargo: dev
          ─► (auto) staging ─► you: promote.sh prod-a1 ─► 10 min ─► (auto) prod-a2 ─► 10 min ─► (auto) prod-b1
```

**Before you start**

```bash
scripts/bootstrap-vault.sh unseal            # after any restart
kubectl get applications -n argocd           # all Synced / Healthy
kubectl get stages -n local-eks-platform     # every stage Healthy, same Freight
docker ps --filter name=github-runner        # runner Up
scripts/check-expiry.sh                      # CI token and Kargo token still valid
git pull && versions                         # write down where every copy is now
probe > /tmp/probe.log &
```

**Steps.** Write the time next to each one; the timings are the result.

1. **Code.** Change the `note` in `apps/frontend-api/main.py`'s `healthz` to `"round-3"`. Commit and push that one file.
2. **CI.** `gh run watch`. Both images build as `1.2.N`, get pushed and scanned, then the run stops at **Waiting**.
3. **Approve.** GitHub → Actions → the run → Review deployments → `dev` → Approve and deploy.
4. **dev.** CI creates the Promotion. Check: `git pull && git log --oneline -3` shows `dev: frontend-api 1.2.N, crud-api 1.2.N (promoted by Kargo)`; `versions` shows dev at `1.2.N`.
5. **staging, by itself.** Nobody touches anything. Watch `kubectl get stages -n local-eks-platform -w`. Check: a `staging: ... 1.2.N` commit by Kargo, staging at `1.2.N`. If nothing happens within 5 minutes, look at `kubectl get stage dev -n local-eks-platform -o yaml` (is the Freight *verified* in dev?) and at the ProjectConfig. That's a finding either way.
6. **Try to skip.** `scripts/promote.sh prod-a2 1.2.N` must be refused. Note the message.
7. **Wave 1.** `scripts/promote.sh prod-a1 1.2.N`. Check with `versions`: prod-a1 new, prod-a2 and prod-b1 still old. Odd users now get the new release, even users the old one.
8. **Waves 2 and 3, by themselves.** Don't touch anything. prod-a2 about 10 minutes after prod-a1 becomes Healthy, prod-b1 about 10 minutes after that.
9. **Done.** `versions` shows `1.2.N` everywhere. `curl -s localhost:7080/healthz` returns `"note":"round-3"`. `kill %1; sort /tmp/probe.log | uniq -c`.

**Pass:** 5 Kargo commits (dev, staging, prod-a1, prod-a2, prod-b1), 1 command typed for prod, 0 non-200 lines in the probe.

**Record** in roadmap.md: the run number, times of each step, the probe counts, and anything surprising. Then fill in the table:

| Step | Expected | Measured |
|---|---|---|
| push → CI waiting for approval | ~2 min | |
| approve → dev serving | ~1–2 min | |
| dev → staging (automatic) | first time ever | |
| prod-a1 → prod-a2 | ~10–13 min | |
| prod-a2 → prod-b1 | ~10–13 min | |
| failed requests | 0 | |

---

## Lab 1. Trace the desired state

**Goal:** for any pod, find the Git lines that made it. Read-only; nothing changes.

GitOps rests on one chain. Learn it once and every other lab gets easier:

```text
root.yaml (applied by hand, once)
 └─ k8s-manifests/argocd/           region-a.yaml, region-b.yaml, projects.yaml, profile.yaml
     └─ profile.yaml → profiles/bigtech/apps.yaml  (ApplicationSet prod-cells)
         └─ Application crud-api-prod-a2
             └─ charts/base-api  +  apps/common/crud-values.yaml  +  apps/prod/prod-a2/crud-values.yaml
                 └─ Deployment crud-api in namespace prod-a2 → pod
```

1. Pick the pod: `kubectl get pods -n prod-a2 -l app=crud-api -o wide`.
2. Walk up the owners: `kubectl get deploy crud-api -n prod-a2 -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}'`. Find the label that names the Argo CD app.
3. Read the app: `kubectl get application crud-api-prod-a2 -n argocd -o yaml`. Find `source.path`, `helm.valueFiles`, `destination`, `project`, and `status.sync.revision`.
4. Who created that app? `kubectl get application crud-api-prod-a2 -n argocd -o jsonpath='{.metadata.ownerReferences[*].kind}/{.metadata.ownerReferences[*].name}'`. Then who created *that*?
5. Render it yourself and compare with the cluster:
   ```bash
   A=k8s-manifests/apps
   helm template crud-api k8s-manifests/charts/base-api -n prod-a2 \
     -f $A/common/crud-values.yaml -f $A/prod/prod-a2/crud-values.yaml > /tmp/rendered.yaml
   grep -E 'image:|DB_NAME' -A1 /tmp/rendered.yaml
   kubectl get deploy crud-api -n prod-a2 -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```
6. Match the commit: `git log -1 --format='%h %s' <status.sync.revision>`.

**Check:** fill this table from Git alone, then confirm it against the cluster.

| Copy | Argo CD app | Values files | Image tag | Database | Commit it's synced to |
|---|---|---|---|---|---|
| dev | | | | | |
| staging | | | | | |
| prod-a1 | | | | | |
| prod-b1 | | | | | |

**Questions**

1. Which single file, if deleted, would make Argo CD remove all three prod cells? *`profiles/bigtech/apps.yaml` (the ApplicationSet), because its apps carry the resources finalizer. Deleting `argocd/profile.yaml` would too, one level up.*
2. Why are two `valueFiles` listed, and which wins on a conflict? *common first, then the copy's own file; the later file wins.*
3. prod-b1 runs in region B. Where does its Argo CD live? *In region A. `destination.name: region-b` is a registered cluster; region B has no Argo CD of its own.*

---

## Lab 2. Drift: what Argo CD fixes, and what it doesn't

**Goal:** predict the outcome of a hand-made change *before* you make it. Write your prediction down for each step, then run it.

All in dev. Watch with `kubectl get application frontend-api-dev -n argocd -w` in a second terminal.

| # | By hand | Predict | What happens and why |
|---|---|---|---|
| 1 | `kubectl delete svc frontend-api-svc -n dev` | | Back in ~1 s. It's in Git, self-heal is on. |
| 2 | `kubectl set env deploy/frontend-api -n dev FLIPT_NAMESPACE=prod` | | Reverted: Git sets that field, so it shows as a diff. Meanwhile dev briefly read prod's flags — a real risk of hand edits. |
| 3 | `kubectl scale deploy frontend-api -n dev --replicas=3` | | Argo CD ignores it: Git sets no `replicas`. The **HPA** puts it back to its minimum, a few minutes later. |
| 4 | `kubectl label deploy frontend-api -n dev owner=me` | | Usually stays: Argo CD compares the fields *it* set. Extra fields are invisible to the diff. |
| 5 | `kubectl create configmap scratch -n dev --from-literal=a=b` | | Stays forever: no app owns it, so nothing prunes it. |
| 6 | `kubectl delete application frontend-api-dev -n argocd` | | The `root` app recreates the Application from `argocd/region-a.yaml`. Does the Deployment survive meanwhile? Look. |

**Then:** turn self-heal off for one app **in Git** (`selfHeal: false` for `frontend-api-dev` in `argocd/region-a.yaml`), push, repeat step 2. Now the app shows `OutOfSync` and stays wrong until someone syncs. Put `selfHeal: true` back.

**Clean up:** `kubectl label deploy frontend-api -n dev owner-` and `kubectl delete configmap scratch -n dev`. (Rows 4 and 5 are the lesson: GitOps only protects what's in Git.)

**Questions**

1. Row 3: why doesn't the chart set `replicas`? *So the HPA and Argo CD don't fight over the same field.*
2. When would you *want* self-heal off? *During an incident, when you must hot-fix by hand before Git catches up. Then turn it back on and put the fix in Git.*

---

## Lab 3. Change one environment, predict the diff first

**Goal:** see exactly what a commit will change in each copy **before** you push it, like a pull-request preview. This is the pending roadmap exercise 5.

1. **Plan.** Staging only: `LOG_LEVEL: debug` under `env:` and `autoscaling.minReplicas: 2` in `apps/staging/frontend-values.yaml`.
2. **Preview.** Render every copy before and after, and diff:
   ```bash
   render() { A=k8s-manifests/apps
     for c in dev staging prod/prod-a1 prod/prod-a2 prod/prod-b1; do
       helm template frontend-api k8s-manifests/charts/base-api -f $A/common/frontend-values.yaml -f $A/$c/frontend-values.yaml > /tmp/$1-${c//\//_}.yaml
     done; }
   git stash && render before && git stash pop && render after
   for f in /tmp/after-*.yaml; do echo "== $f"; diff "${f/after/before}" "$f"; done
   ```
   **Check:** only the staging file differs. Write down the lines.
3. **Ship.** Commit, push, `refresh frontend-api-staging`. Confirm with `kubectl get deploy frontend-api -n staging -o jsonpath='{.spec.template.spec.containers[0].env}'` and `kubectl get hpa -n staging`.
4. **Now the wide one.** Make the same `LOG_LEVEL` change in `apps/common/frontend-values.yaml` instead. Run the preview again: how many copies change? Don't push this one. Revert it with `git checkout`.
5. **Revert** the staging change with `git revert <sha>` and push.

**Questions**

1. Staging's new pod rolls out, but did its image tag change? Why not? *No: the tag is only set by Kargo, in the same file, and you didn't touch that key.*
2. Kargo writes to `apps/staging/frontend-values.yaml` too. What happens if you and Kargo push at the same moment? *One push is rejected as non-fast-forward. Kargo's promotion fails and is retried; yours needs `git pull --rebase`.*

---

## Lab 4. Add and remove resources: prune, finalizers, order

**Goal:** create and delete things through Git only, and understand what decides *if* and *in which order* they go.

1. **Add.** Create `k8s-manifests/platform/region-a/networking/hello-route.yaml`: a VirtualService on `platform-gateway` for host `dev.localhost`, path `/hello`, rewritten to `/healthz` on `frontend-api-svc.dev.svc.cluster.local`. Push, refresh `platform-networking-dev`. **Check:** `curl -s -H 'Host: dev.localhost' localhost:8080/hello` → 200.
2. **Remove by deleting the file.** `git rm` it, push, refresh. **Check:** 404. That's **prune**.
3. **Protect from prune.** Add it back with the annotation `argocd.argoproj.io/sync-options: Prune=false`, push. Delete the file again. **Check:** still 200, and the app shows the resource as *orphaned/requires pruning*. Delete it by hand to finish. This is how phase 8 moved live resources between apps without an outage (see findings).
4. **Order.** Read the `argocd.argoproj.io/sync-wave: "-1"` on `argocd/projects.yaml` and the Kargo `Project`. Explain why they need it. Then answer: what happens to an app whose project doesn't exist yet? *Argo CD rejects it until the project appears, and syncs once it does.*
5. **Finalizers.** Compare `metadata.finalizers` on `prod-routing-region-a` (has `resources-finalizer.argocd.argoproj.io`) with `frontend-api-dev` (doesn't). Predict: deleting each Application, what happens to its Deployment/VirtualService? Check your answer against the Argo CD docs, not the cluster. (Deleting prod routing would cut prod traffic.)

**Questions**

1. Why does `platform-networking-dev` own the `staging` namespace, and why do the staging apps have a `retry` block? *Namespaces are cluster-wide, so the nonprod project can't create them. The apps retry until the platform app has made the namespace.*

---

## Lab 5. Promotion is a commit: gates and the audit trail

**Goal:** treat Git as the release log. Answer release questions without looking at the cluster, then check.

1. **History.** `git log --author=Kargo --format='%h %ad %s' --date=iso -20`. When did the current prod version reach each cell? How long did each wave take?
2. **Which Freight is where.**
   ```bash
   kubectl get stages -n local-eks-platform \
     -o custom-columns=STAGE:.metadata.name,FREIGHT:.status.freightHistory[0].items.*.name,HEALTH:.status.health.status
   kubectl get freight -n local-eks-platform -o custom-columns=ALIAS:.alias,TAGS:.images[*].tag,VERIFIED_IN:.status.verifiedIn
   ```
   (Field names differ between Kargo versions; if a column is empty, look at `-o yaml` and adjust.)
3. **Gates.** For each stage, from `platform/region-a/kargo/kargo.yaml` and `profiles/bigtech/kargo/prod-waves.yaml`, write: where Freight may come from, whether it auto-promotes, the soak time.
4. **Prove the gates.** Pick an *older* Freight that staging has but prod-a1 doesn't. Try `promote.sh prod-a2 <that version>`: refused. Why? *prod-a2 only accepts Freight that has soaked in prod-a1.*
5. **Who promoted what.** Kargo commits as "Kargo", so who pressed the button? `kubectl get promotions -n local-eks-platform --sort-by=.metadata.creationTimestamp` and `-o yaml` on one: look for the creator annotation. Compare dev (CI's `ci-promoter`), prod-a1 (you), prod-a2 (Kargo itself).

**Questions**

1. Why do both apps travel as one Freight? *They're tested together in staging; shipping crud-api 1.2.9 with frontend-api 1.2.8 would be an untested pair.*
2. What's missing from the audit trail compared to a big company? *An approval record for prod (a PR, a ticket), and a reason. Here, the shell history is the only record of who ran `promote.sh prod-a1`.*

---

## Lab 6. Stop a bad release: freeze the waves, roll back one cell

**Goal:** a release reaches prod-a1 and misbehaves. Contain it, then undo it properly. Needs one newer version than prod runs (R3 gives you one).

1. **Prepare a bad release.** Make `/users/{id}` fail for one user: in `apps/frontend-api/main.py`, return HTTP 500 when `user_id == "7"`. Push, approve, let it reach staging. Notice that nothing caught it: that's why real platforms add tests and analysis (roadmap Group 2, Group 3).
2. **Wave 1.** Start the probe, plus a line for user 7: `curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/users/7`. Promote to prod-a1.
3. **Freeze the waves in Git** before prod-a2's 10 minutes are up: remove the `platform.local/auto-promote: "true"` label from `prod-a2` and `prod-b1` in `profiles/bigtech/kargo/prod-waves.yaml`, push, `refresh prod-kargo`. **Check:** after 10 minutes prod-a2 still runs the old version. (Race: if it promoted already, roll it back in step 5 too.)
4. **Wrong way first (read, don't run):** `git revert` of Kargo's `prod-a1:` commit would put the old tag back, but Kargo would still think prod-a1 holds the new Freight. The findings table has this one.
5. **Right way:** `scripts/promote.sh prod-a1 <previous version>`. Kargo allows it: prod-a1 already had that Freight. **Check:** user 7 → 200, `versions`, and a new Kargo commit.
6. **Fix forward.** Revert the code change, push, approve. The fixed release goes through dev and staging by itself.
7. **Unfreeze** (put the labels back) *before* promoting the fix to prod-a1, and watch the waves carry it all the way.

**Pass:** the bad version reached prod-a1 only. User 7 got errors on `localhost:8080` (odd users go to prod-a1) but not on `localhost:9080` (prod-b1). The probe for prod-a2 and prod-b1 shows 0 errors.

**Questions**

1. How many users were affected, as a share? *Only users routed to prod-a1 who asked for user 7. That's the point of cells.*
2. In the small profile, what would the same bad release have hit? *All prod users, unless the canary weight was holding it at 10%.*

---

## Lab 7. Guardrails: projects and change freezes

**Goal:** make mistakes impossible, not merely unlikely. Every step is a commit to `argocd/`.

1. **Wrong destination.** Temporarily change `frontend-api-staging`'s destination namespace to `prod-a1` in `argocd/region-a.yaml`. Push. **Check:** `InvalidSpecError ... not permitted in project 'nonprod'`, and prod-a1 untouched. Revert.
2. **Wrong kind.** Read `clusterResourceWhitelist: []` in `argocd/projects.yaml`. Predict what happens if dev's chart tried to create a cluster-wide object (a `Namespace` or `ClusterRole`). Then check it: temporarily add a `ClusterRole` template to the chart, guarded by a value that only `apps/dev/frontend-values.yaml` turns on, and push. *Sync fails: the resource kind isn't permitted in project `nonprod`. Nothing else in dev is affected.* Remove both again.
3. **Change freeze.** Add a sync window to the `prod` project:
   ```yaml
   syncWindows:
     - kind: deny
       schedule: "* * * * *"   # every minute, i.e. always, while it's in Git
       duration: 1h
       applications: ["*"]
       manualSync: false
   ```
   Push. Then promote a version to prod-a1. **Observe (not tested here yet):** Kargo commits the tag to Git, but Argo CD doesn't sync; what does the Stage show? What does `kubectl get application frontend-api-prod-a1 -n argocd` show? Remove the window: the sync goes through. Record what you saw in findings.md.
4. **Who can change the guardrails?** Anyone who can push to `main` can edit `projects.yaml`. Write down how a company closes that gap. *Branch protection with required reviews, CODEOWNERS for `argocd/`, and a platform team owning the projects.*

---

## Lab 8. Fleets: a new cell from one list entry

**Goal:** add `prod-a3` as a real cell, serve users from it, then retire it cleanly. This is exercise 10's first half. The checklist is in the README ("Add a cell").

1. **Order matters.** Plan the commits so nothing starts before what it needs:
   1. namespace `prod-a3` (`platform/region-a/networking/namespaces.yaml`) and the `prod` project destination (`argocd/projects.yaml`);
   2. database and Vault role: add `prod-a3` to `ENVIRONMENTS` in `scripts/bootstrap-vault.sh`, run `scripts/bootstrap-vault.sh databases` (the one step outside Git: say why);
   3. values in `apps/prod/prod-a3/` (copy prod-a2's, change every `a2`);
   4. one element in the ApplicationSet list;
   5. a Kargo stage `prod-a3` (source `prod-a2`, soak, auto-promote label);
   6. a route: `x-cell: prod-a3` pin in `profiles/bigtech/routing-region-a/prod-router.yaml`.
2. Push each, `kubectl get applications -n argocd -w`. **Check:** `curl -s -D - -H 'x-cell: prod-a3' localhost:8080/users/1 | grep -i x-cell` → `prod-a3`, and the probe never failed for the other cells.
3. **Release into it.** It starts at whatever tag its values say. Let the next promotion flow through the wave.
4. **Retire** in the reverse order: route, Kargo stage, list element (watch the finalizer clean up the namespace's apps), values, project destination, namespace. Measure how long each took. Leave the database, or drop it: what's the risk of each?

**Questions**

1. Why is the Kargo stage a separate commit from the ApplicationSet entry? *A stage with no app to sync would fail its first promotion; add the target first.*
2. What would you change so a cell is truly one line? *Generate the namespace, route and stage from the same list (a second ApplicationSet or a chart for cells).*

---

## Lab 9. Broken Git: bad commits and how to read them

**Goal:** push something broken on purpose, read what each tool says, and pick fix-forward or revert. **dev only.** One break at a time; fix it before the next.

| # | Break (in dev files) | Where the error shows | What still serves traffic? |
|---|---|---|---|
| 1 | Invalid YAML in `apps/dev/frontend-values.yaml` (bad indent) | App `Unknown` / `ComparisonError` in `.status.conditions` | Everything: nothing was applied |
| 2 | `image.tag: 9.9.9` (doesn't exist) | Pod `ImagePullBackOff`; app `Progressing`, later `Degraded` | The old pod (rolling update never finishes) |
| 3 | `CRUD_API_URL` pointing at `crud-api-svc.staging` | App `Synced` / `Healthy`; requests `403` | Nothing for users: GitOps can't tell you the config is *wrong*, only that it's *applied* |
| 4 | An unknown field in `feature-flags/dev.features.yaml` | Flipt CrashLoopBackOff; `kubectl logs deploy/flipt -c flipt` | Frontends fall back to flag off (v1). Look at `is_feature_enabled` in `main.py` for why |

For each:

1. Predict the row before pushing.
2. Push, refresh, find the error: `kubectl get application frontend-api-dev -n argocd -o jsonpath='{.status.conditions}{"\n"}{.status.health}{"\n"}{.status.operationState.message}'`.
3. Fix it with **either** `git revert` **or** a new commit. Say which and why.

**Questions**

1. Row 2 left the old pod serving. Which setting made that safe? *The rolling update keeps old pods until new ones are Ready (readiness probe).*
2. Row 3 is the dangerous one. What would have caught it? *A smoke test after sync (Kargo verification / Argo Rollouts analysis), or an error-rate alert.*
3. Row 4: why is `flag.sh` useful here? *It asks Flipt the same question the app asks.*

---

## Lab 10. Capstone: rebuild from Git, then run a release alone

**Goal:** prove Git is the backup, then run a full release with no notes open, and write it up.

**Part A: lose an environment.** In dev only:

1. Record `versions`, and `kubectl get all -n dev`.
2. `kubectl delete namespace dev`. Watch what comes back by itself and what doesn't. (The namespace comes from `platform-networking-dev`; the apps from their Applications; the DB login from Vault. The `curl` test pod doesn't: it was never in Git.)
3. Time it to `200` on `dev.localhost`. Write down every manual step you needed: each one is a gap in "everything is in Git".

**Part B: a release, start to finish, on your own.** Pick a small, visible change that also needs a flag. For example: a new field in the v2 response, behind a new flag that's **off in prod**.

1. Flag in `feature-flags/*.features.yaml`: on in dev and staging, off in prod.
2. Code change; CI; approve; dev; staging.
3. Prod waves with the probe running.
4. Turn the flag on for prod at 50% (a `rollouts:` threshold), then 100%, each a commit.
5. Tidy up: code no longer needs the flag? Remove it in a later release.

**Part C: write the record.** Using only `git log`, `gh run list` and Kargo's promotions, write a half-page release note in `notes/`: what changed, the commits, when each cell got it, flag steps, probe result, anything that surprised you. If you can't answer something from those three sources, that's the finding.

---

## Labs 11–20: going deeper

From here on some steps haven't been run on this platform yet. They're marked **(untested)**. Expect findings, and write them in [findings.md](findings.md).

---

## Lab 11. Sync hooks: run a check as part of the deploy

**Goal:** a deploy counts as done only when the app answers. Argo CD runs a Job after every sync of dev's frontend. If the Job fails, the sync fails, and so does Kargo's promotion.

1. **Chart.** Add `smokeTest: {enabled: false}` to `charts/base-api/values.yaml` and a template `charts/base-api/templates/smoke-test.yaml`:
   ```yaml
   {{- if .Values.smokeTest.enabled }}
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: {{ .Values.nameOverride }}-smoke
     annotations:
       argocd.argoproj.io/hook: PostSync
       argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
   spec:
     backoffLimit: 1
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: smoke
           image: curlimages/curl
           args: ["-fsS", "--retry", "5", "--retry-all-errors", "http://{{ .Values.nameOverride }}-svc/users/1"]
   {{- end }}
   ```
   Preview first (Lab 3): no copy changes while it's off.
2. **Turn it on in dev only** (`smokeTest.enabled: true` in `apps/dev/frontend-values.yaml`). Push, refresh. **Check:** `kubectl get jobs -n dev -w` shows the Job run and disappear; the app's `.status.operationState.phase` is `Succeeded`.
3. **Sidecar trap (untested).** dev has Istio injection. If the Job never finishes, the `istio-proxy` sidecar is keeping the pod alive. Check whether `istio-proxy` is listed under `initContainers` (a native sidecar, which exits with the Job) or `containers` (it doesn't exit). Write down which one you get and how you fixed it.
4. **Break it.** Change the path to `/nope`, push. **Check:** the sync is `Failed`, the app's pods still serve (the hook runs *after* apply), and the next Kargo promotion to dev fails at `argocd-update`, so staging doesn't auto-promote. Revert.

**Questions**

1. PostSync runs after the new pods are applied. How would you check *before* them (a DB migration, say)? *A `PreSync` hook. If it fails, nothing is applied.*
2. Why `BeforeHookCreation`? *Job specs are immutable. The old Job has to go before the next sync can create a new one.*

---

## Lab 12. Tuning the diff: ignoreDifferences and server-side apply

**Goal:** fix "always OutOfSync" noise without hiding real drift.

1. **Make some noise.** In `profiles/bigtech/kargo/prod-waves.yaml` write `requiredSoakTime: 10m` (not `10m0s`) for prod-b1. Push. **Check:** `prod-kargo` is `OutOfSync` forever and the diff shows `10m` vs `10m0s`. This really happened (findings).
2. **Fix A: ignore the field.** Add to the `prod-kargo` Application in `profiles/bigtech/apps.yaml`:
   ```yaml
   ignoreDifferences:
     - group: kargo.akuity.io
       kind: Stage
       jsonPointers: [/spec/requestedFreight]
   ```
   It goes green. Now change prod-b1's source stage in Git to `staging`. Does Argo CD notice? *No: you've blinded it to the field that decides which Freight prod-b1 may take.*
3. **Fix B: say it the way the cluster says it.** Remove `ignoreDifferences`, write `10m0s`. Green, and still watched. This is usually the right fix.
4. **Fix C: server-side diff (untested).** Add `argocd.argoproj.io/compare-options: ServerSideDiff=true` to the Application. Does the API server normalise `10m` for the diff? Record the result.
5. **The dangerous one, in dev.** Put `ignoreDifferences` on `/spec/template/spec/containers/0/image` for `frontend-api-dev`, plus the sync option `RespectIgnoreDifferences=true`. Set a different image by hand. Argo CD shows green and never puts it back. Remove it all.

**Questions**

1. When is `ignoreDifferences` right? *For a field another controller legitimately owns, like a replica count set by an HPA, or a caBundle injected by a webhook. Never for a field that's in Git.*

---

## Lab 13. Flags as GitOps: release a behaviour, not a build

**Goal:** ship behaviour separately from code. Every flag step is a commit, promoted dev → staging → prod.

1. **Read the history.** `git log --oneline -- feature-flags/`. `git show 18b5764` is a tested rollout: off by default, on for the `beta-testers` segment (`plan=beta`), and 50% for everyone else.
2. **dev.** Copy that shape into `dev.features.yaml`. Push. Within ~30 s: `scripts/flag.sh users` and `scripts/flag.sh 2 beta`. Which users are in the 50%? Push again with no change to the percentage. Is it the same users? *Yes: the split is a hash of the user ID, so it's stable.*
3. **Promote the flag.** Copy the same block into `staging.features.yaml`, then `prod.features.yaml`, **each a separate commit**, checking `FLIPT_NAMESPACE=staging scripts/flag.sh users` in between. That's a flag promotion done by hand, the way a release goes through Kargo.
4. **Regions.** Right after the prod push, loop `curl localhost:8080/users/2` and `localhost:9080/users/2` together. Do they disagree for a few seconds? *Two Flipts, each polling Git.*
5. **Kill switch.** `enabled: false` with no rollouts, in prod. Time from push to every cell answering v1. Then restore to `enabled: true` with no rollouts.

**Questions**

1. Flag changes skip Kargo, CI and the waves. Is that good? *It's fast, which a kill switch needs. But a bad flag reaches every prod cell at once. The roadmap has "promote flag changes region by region" for this reason.*
2. What does the frontend do if Flipt is down? *The flag reads as off (`is_feature_enabled` returns False), so users get v1. Is that the safe default for this flag?*

---

## Lab 14. Secrets in a GitOps repo

**Goal:** Git holds the *reference* to a secret, Vault holds the value, and a leak can't get committed.

1. **Try to leak one.** Put a fake GitHub-style token in a scratch file: `ghp_` followed by 36 letters and digits. `git add` it and commit. **Check:** the gitleaks pre-commit hook refuses (run `pre-commit install` first if it's not installed). Delete the file. What would you do if it had gone to GitHub? *Rotate first; rewriting history doesn't make it safe.*
2. **A new secret for dev's frontend.** In Vault (outside Git, say why): `kv/frontend/dev` with `banner=hello`; a policy that can read only that path; a Kubernetes-auth role bound to `sa/frontend-api` in `dev`. Look at how `scripts/bootstrap-vault.sh` does roles for crud-api.
3. **In Git:** a `VaultAuth` and a `VaultStaticSecret` in `dev` (copy the shape from `platform/region-a/kargo/kargo.yaml`), with `rolloutRestartTargets` pointing at the `frontend-api` Deployment. Then `secretEnv: {BANNER: {secret: frontend-banner, key: banner}}` in `apps/dev/frontend-values.yaml`. Decide where the two manifests live. They go in the chart behind a value (like `vaultDbCredentials`), because the `nonprod` project can deploy only into `dev` and `staging`, and the chart is what it deploys.
4. **Check:** `kubectl get secret frontend-banner -n dev -o jsonpath='{.data.banner}' | base64 -d`, and `git grep hello` finds nothing.
5. **Rotate.** Change the value in Vault. **Check:** the Secret updates within `refreshAfter` and the frontend pods restart. Nothing changed in Git. Is that a GitOps violation? *No. Git declares where the secret comes from, not what it is.*
6. Remove it all: Git first, then the Vault role, policy and value.

---

## Lab 15. Pull requests: preview every change, protect main

**Goal:** nobody pushes straight to `main`. Every change gets a rendered diff for review. Then deal with the robot that does push to `main`.

1. **Render-diff workflow.** Add `.github/workflows/render-diff.yml`, triggered on `pull_request` and running on **`ubuntu-latest`**, never the self-hosted runner (see the README's security note). Give it `permissions: contents: read` and no secrets. Steps: check out with `fetch-depth: 0`, install Helm, render every copy of both apps at the base commit and at the PR head (the Lab 3 loop), and write the `diff` to `$GITHUB_STEP_SUMMARY`.
2. **Use it.** Branch, change `apps/staging/frontend-values.yaml`, `gh pr create`. **Check:** the summary shows only staging's lines. Merge. Argo CD deploys it as usual.
3. **Protect `main`** (Settings → Rules): require a pull request. Now run `scripts/promote.sh prod-a1 <version>`. **Check:** the promotion fails at `git-push`. Kargo, `profile.sh` and you are all blocked.
4. **Choose a fix** and explain why (at least one untested):
   - Let Kargo's token bypass the rule. Quick, but every promotion goes unreviewed again.
   - Change prod-a1's promotion steps to `git-open-pr` + `git-wait-for-pr`, so a prod release becomes a PR you approve. Leave dev and staging pushing directly.
   - A branch per stage (Kargo's `stage/<name>` pattern, Argo CD `targetRevision` per stage) instead of folders on `main`.
5. Undo the rule when done, or keep it and update the README.

**Questions**

1. The PR workflow runs on GitHub's machines. Why is that safe when the self-hosted runner isn't? *It's a throwaway VM with no access to your laptop, and it gets no secrets on PRs.*

---

## Lab 16. Kargo verification: a smoke test gates the next stage

**Goal:** today staging auto-promotes when dev is *Healthy*, and Healthy only means "pods are running". Make it mean "the app answers correctly". (untested)

1. **An AnalysisTemplate** in `platform/region-a/kargo/` (Argo Rollouts is installed for this):
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: smoke-dev
     namespace: local-eks-platform
   spec:
     metrics:
     - name: smoke
       provider:
         job:
           spec:
             backoffLimit: 1
             template:
               spec:
                 restartPolicy: Never
                 containers:
                 - name: smoke
                   image: curlimages/curl
                   # Through the gateway: this namespace has no sidecar, and
                   # STRICT mTLS rejects plaintext calls to the services.
                   args: ["-fsS", "-H", "Host: dev.localhost",
                          "http://istio-ingressgateway.istio-system/users/7"]
   ```
2. **Use it** on the `dev` Stage: `spec.verification.analysisTemplates: [{name: smoke-dev}]`. Push.
3. **Good release.** Run R3 again. **Check:** `kubectl get analysisruns -n local-eks-platform` shows `Successful`, and staging auto-promotes after it, not before. How much later than before?
4. **Bad release.** Ship Lab 6's user-7 bug. **Check:** the AnalysisRun fails, the Freight is not verified in dev, and **staging never gets it**. Nobody had to notice. Compare with Lab 6, where it reached prod-a1.
5. **Extend.** Add the same verification to `prod-a1`, calling the gateway with `x-cell: prod-a1`. A bad version in prod-a1 now also stops prod-a2 and prod-b1, without the freeze from Lab 6.

**Questions**

1. What does one curl not catch? *Slow responses, other users, errors that only show under load. That's why real platforms analyse error-rate metrics (roadmap: observability).*

---

## Lab 17. Progressive delivery with Argo Rollouts

**Goal:** a canary in dev that moves 20% → 50% → 100% by itself, and aborts on a failed check. Compare it with the hand-driven canary (guide Lab 11) and the cell wave (Lab 6). (untested; plan on findings)

1. **Clear the ground.** Turn dev's hand canary off (weights `100`/`0`, then `canary.enabled: false`: two commits, as usual).
2. **A Rollout that points at the existing Deployment** (`workloadRef`), so the chart barely changes. Behind a value, dev only:
   - `strategy.canary.trafficRouting.istio`: dev's frontend VirtualService and DestinationRule (the `stable`/`canary` subsets in `platform/region-a/networking/istio-networking.yaml`);
   - steps: `setWeight: 20`, `pause: {duration: 2m}`, `analysis` with Lab 16's template, `setWeight: 50`, `pause: {duration: 2m}`;
   - `workloadRef.scaleDown: progressively`, and point the HPA's `scaleTargetRef` at the Rollout.
3. **Watch a release.** Let Kargo promote a new version to dev. `kubectl get rollout frontend-api -n dev -w` and a 200-request loop, as in the guide's Lab 11. **Check:** the weights change on their own, and the version counts follow.
4. **Abort.** Ship the user-7 bug to dev. **Check:** the analysis fails, the Rollout aborts back to stable, and the users who saw errors are about 20%.
5. **Argo CD's view.** What does `frontend-api-dev` show during a paused Rollout? Who "owns" the VirtualService weights now: Git or the Rollout controller? *The controller changes them live, so you need `ignoreDifferences` on those weights (Lab 12). This is a case where it's right.*

**Questions**

1. Waves (cells), Istio weights (small profile), Rollouts: when would you pick each? *Waves limit blast radius by users and infrastructure. Weights split traffic in one copy. Rollouts automate the weights with analysis. Big companies often use waves across cells and Rollouts inside each cell.*

---

## Lab 18. Lose the hub: when Argo CD itself is down

**Goal:** know what GitOps tooling is and isn't in the path of your users.

1. Start the probe. Stop Argo CD's brain: `kubectl scale statefulset argocd-application-controller -n argocd --replicas=0`.
2. Predict, then check each:
   - Requests to all three cells. *Still 200: Argo CD isn't in the data path.*
   - `kubectl delete svc frontend-api-svc -n dev`. *Not healed.* (Put it back by restoring the controller, not by hand.)
   - Push a values change to dev. *Nothing happens.*
   - `scripts/promote.sh staging <version>`. *Kargo commits to Git; what happens at `argocd-update`? Record it.*
   - Flag change in `dev.features.yaml`. *Still works: Flipt reads Git itself.*
   - Region B: `kubectl --context kind-region-b get pods -n prod-b1`. *Running. Its apps are managed from region A, so region B is now frozen too.*
3. Restore `--replicas=1`. Time how long until every app is `Synced` again and the Service is back.
4. Write down: in a real company, what's the blast radius of losing the one Argo CD that manages every cluster? *No changes anywhere, including emergency fixes. That's why some run one Argo CD per region or cluster.*

---

## Lab 19. Adopt the hand-installed pieces

**Goal:** bring a tool that was installed with `helm install` under Argo CD without restarting it. This is roadmap Group 5, and how Flipt was adopted (findings).

1. **Start small: metrics-server.** Find what's installed: `docker exec dev-cluster-control-plane sh -c 'KUBECONFIG=/etc/kubernetes/admin.conf helm list -n kube-system'` and its values (`helm get values`).
2. **Application** in `argocd/region-a.yaml`: the metrics-server chart repo, the **same chart version, release name and values** (`args: [--kubelet-insecure-tls]`), namespace `kube-system`, project `default`. Before pushing, note the pod's name and age.
3. Push. **Check:** the app goes `Synced`, and the pod has the same name and age (adopted, not replaced). If it restarted, what differed? Compare the rendered chart with the live object.
4. **Clean up Helm's record** (`sh.helm.release.v1.metrics-server.*` Secrets in `kube-system`), so nobody runs `helm upgrade` against a release Argo CD now owns.
5. **Region B:** the same app with `destination.name: region-b`, or better, an ApplicationSet over both clusters (Lab 8's pattern).
6. **Next candidates, harder each time:** cert-manager (CRDs: use `ServerSideApply=true`), Kargo (Argo CD and Kargo managing each other), Istio (istioctl → the `base`/`istiod`/`gateway` charts), Vault (stateful, and must be unsealed). For each, write what could go wrong during adoption.

**Questions**

1. Should Argo CD manage itself? *Many do, via an Application pointing at its own install manifests. But a bad commit can then break the tool you need to fix it. Know how to recover by hand first.*

---

## Lab 20. Final: the platform from an empty laptop

**Goal:** prove the README's "Setup from scratch". This is the roadmap's first open item, and it's never been done.

**This deletes both clusters.** Everything declared in Git comes back. Everything else doesn't: Kargo's Freight history, Zot's images, the Vault keys and every secret in it, and the runner registration. Do it on a day with time to spare.

1. **Before.** Save `~/.local-eks-platform/` elsewhere (in case you need to go back). Write down every tool's version. Push everything and make sure `git status` is clean. List what you think *isn't* in Git.
2. **Delete:** `kind delete cluster --name dev-cluster`, the same for `region-b`, and remove the `global-lb`, `zot-proxy` and `github-runner` containers.
3. **Rebuild** by following the README exactly, with a stopwatch. Every time you have to do something the README doesn't say, **stop and write it down**. Those are the findings.
4. **Images.** The values files name tags that no longer exist in the new Zot, so apps sit in `ImagePullBackOff`. Rebuild through CI (`gh workflow run build-and-promote`), then promote through the stages. What does each prod cell run until then?
5. **Pass:** all apps `Synced` / `Healthy`, R3 passes again, and the README is updated with every gap you found.
6. **Last question:** how long did it take, and how many of those minutes were things Git couldn't do for you (Vault init, tokens, runner)? That list is the rest of your roadmap.

---

## When you've done all twenty

You've gone from reading Git, to running releases, to building the guardrails and gates, to rebuilding the platform from Git alone. What's left is in the roadmap: observability (so the Lab 16 and 17 checks can use error rates), policy with Kyverno, image signing, and the real-account version in [eks-auto-mode.md](eks-auto-mode.md).
