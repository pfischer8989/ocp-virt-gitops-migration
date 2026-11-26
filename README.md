# ocp-virt-gitops-migration

**Declarative VM migration demo:** migrate VMware workloads to OpenShift Virtualization and run them afterwards through a GitOps operating model.

- **Git** defines *what* gets migrated: migration waves are pull requests.
- **Argo CD** turns merged waves into MTV Plans and later manages the migrated VMs.
- **Ansible Automation Platform** controls *when*: readiness checks, a human approval gate, execution, monitoring and validation.

Built for the *OpenShift Virtualization Migration* Red Hat Demo Platform lab (vCenter + OpenShift 4.18 + MTV + AAP + ACM). It reuses the app-of-apps conventions from [`aws-open-ocp-argo`](../aws-open-ocp-argo).

## Story

| Part | What the audience sees | Value |
|---|---|---|
| **1. Define the migration with GitOps** | A PR adds `migration-waves/wave-01/`. It gets merged, and Argo CD syncs the MTV Plan, NetworkMap and StorageMap. MTV validates them. **Nothing migrates yet.** | Repeatable, reviewable migrations with no manual configuration |
| **2. Orchestrate with AAP** | The workflow runs readiness checks, which **fail** (a source VM is powered on). After the fix they pass. Someone approves, AAP starts the migration, follows progress and validates VM and app health. | Lower migration risk, controlled execution, an audit trail |
| **3. Manage the VM lifecycle with GitOps** | A migrated VM is adopted into Git in place. A PR changes its CPU from 1 to 2 sockets, and Argo CD applies it **live**. A manual console change gets reverted. | Day-2 VM management without manual infrastructure changes |

See **[docs/run-of-show.md](docs/run-of-show.md)** for the timed DO/SAY presenter script.

## Architecture

```
            PR + review                     sync (SSA)
 GitHub  ───────────────►  main  ─────────────────────────►  OpenShift
   │                         │     Argo CD                     │
   │  migration-waves/wave-N │──►  app: migration-waves  ──►   │  Namespace vm-wave-N
   │                         │                                 │  NetworkMap / StorageMap / Plan  (openshift-mtv)
   │  vms/<ns>/<vm>.yaml     │──►  app: vm-lifecycle     ──►   │  VirtualMachine  (adopted, selfHeal)
   │                                                           │
   │                AAP workflow (survey: plan_name)           │
   │   1 Readiness ─► Approval ─► 2 Start ─► 3 Monitor ─► 4 Validate
   │      │                         │                          │
   │      ├─ Argo app Synced?       └─ creates forklift Migration (only place this happens)
   │      ├─ Plan Ready, no Critical/Error conditions
   │      ├─ not already migrated
   │      ├─ target namespace + StorageClass exist
   │      └─ source VMs powered off (vCenter API)
```

Key design decisions:

- **Git never contains a `Migration` object.** A Plan only describes a migration. Execution needs readiness checks and an approval, and AAP's job record ties it back to the Git revision. Argo CD owns *what*, AAP owns *when*.
- **Server-side apply** on both Argo apps. MTV and KubeVirt default fields into their objects, and SSA means Argo only diffs the fields Git owns, so nothing flaps OutOfSync.
- **Nothing that holds VM data is ever pruned.** Wave namespaces and adopted VMs carry `argocd.argoproj.io/sync-options: Prune=false,Delete=false`. Removing a file from Git can't delete a VM.
- **MTV health in Argo CD.** `bootstrap.sh` adds Lua health checks so a Plan shows *Progressing* while MTV validates it, *Healthy* when Ready and *Degraded* on a Critical or Error condition.
- **Live CPU changes.** The cluster uses the `LiveUpdate` VM rollout strategy, the VMs are on RWX block RBD, and `maxSockets` defaults to 4×. A socket change is hot-plugged via live migration, with no reboot.

## Repository layout

```
bootstrap/            One-time: GitOps operator, Argo RBAC, AppProject, root app-of-apps
apps/                 Child Applications: migration-waves, vm-lifecycle
migration-waves/      ← Argo-synced. Part 1 PRs add a directory per wave here
vms/                  ← Argo-synced. Part 3 PRs add vms/<namespace>/<vm>.yaml here
examples/             Wave manifests the PR script copies (wave-01, wave-00-rehearsal)
ansible/              Playbooks run by AAP (readiness, start, monitor, validate)
collections/          requirements.yml, installed by AAP on project sync
scripts/              bootstrap, setup-aap, open-wave-pr, adopt-vm, resize-vm-pr, reset
docs/run-of-show.md   Presenter script
```

## Setup (once per lab environment)

Prerequisites: `oc` logged in as cluster-admin, plus `gh` (authenticated), `jq`, `python3` with PyYAML, and `git`.

```sh
cp config.env.example config.env      # set REPO_TOKEN only if the repo is private

scripts/bootstrap.sh                  # OpenShift GitOps + Argo apps (~3 min)
scripts/setup-aap.sh                  # AAP project, templates, approval workflow
```

Then check:

```sh
oc -n openshift-gitops get applications       # vm-migration-root, migration-waves, vm-lifecycle: Synced/Healthy
```

In AAP, go to **Templates → "VM Migration Wave - Readiness, Approval, Migrate"**.

### Lab-specific values

These were taken from the lab's MTV inventory. If your lab differs, update `examples/*/`:

| | vSphere | OpenShift |
|---|---|---|
| Provider | `vmware` (vCenter) | `host` |
| Network | `segment-migrating-to-ocpvirt` | pod network |
| Datastore | `workloadshare` | `ocs-external-storagecluster-ceph-rbd` (RWX, Block) |
| VMs | `database-user1`, `winweb01-user1`, `winweb02-user1`, `haproxy-user1` | pre-migrated copies in `vmimported` |

## Demo commands

```sh
scripts/open-wave-pr.sh wave-01                 # Part 1: PR that defines the wave
#   merge the PR, then watch Argo CD + Migration → Plans for virtualization
#   launch the AAP workflow (plan_name=wave-01)       # Part 2
scripts/adopt-vm.sh vmimported database         # Part 3: PR that adopts the VM
scripts/resize-vm-pr.sh vmimported database 2   # Part 3: PR that changes CPU 1 → 2
```

## Rehearsing and resetting

- **A vSphere VM can only be migrated once per lab** (MAC addresses would collide). Rehearse the full flow with `scripts/open-wave-pr.sh wave-00-rehearsal`. It migrates `haproxy-user1`, which the app doesn't need on OpenShift.
- `scripts/reset.sh` removes waves and adopted VMs from Git, deletes MTV Migrations, Plans and Maps, and releases adopted VMs from Argo tracking (they keep running). `scripts/reset.sh --vms` also deletes the `vm-wave-*` namespaces and the VMs in them.
- After a resize rehearsal, run `scripts/resize-vm-pr.sh vmimported database 1` **before** resetting so the next delivery starts at 1 socket.

## Team alignment questions (from the demo brief)

| Question | Answer in this repo |
|---|---|
| Can we demonstrate the complete GitOps → AAP → MTV flow? | Yes. A merged PR becomes an Argo-synced Plan, then the AAP workflow runs readiness, approval, the `Migration` object and validation. |
| How will we transition migrated VMs into GitOps management? | `adopt-vm.sh` exports the live VM, strips runtime fields and opens a PR. Argo adopts the VM in place via SSA with no restart. Prune and Delete are disabled. |
| Can we show a real VM configuration change after migration? | Yes. CPU sockets go from 1 to 2 on `vmimported/database` via PR and are hot-plugged live (the guest agent shows the new vCPU). |
| What should be live versus pre-staged for 45–60 minutes? | **Live:** PR and merge, Argo sync, the AAP failure → fix → approve run, the start of the migration, adoption and the resize PR. **Pre-staged:** finished migrated VMs in `vmimported`, because disk copy takes too long for the session. |
