# Run of show — Declarative VM Migration (45–60 min)

Format follows the lab guide: **DO** is what you click or run, **SAY** is the talk track. Keep the vocabulary aimed at VMware admins and avoid Kubernetes jargon ("Pod" and the like) unless the audience brings it up.

| Time | Segment |
|---|---|
| 0–5 | Framing: today vs. target operating model |
| 5–17 | **Part 1:** define the migration wave in Git, Argo CD syncs it |
| 17–37 | **Part 2:** AAP readiness (fail → fix), approval, execution, validation |
| 37–52 | **Part 3:** adopt the VM into Git, CPU change by PR, drift correction |
| 52–60 | Recap and Q&A |

---

## Pre-stage checklist (30 min before)

- [ ] `oc -n openshift-gitops get applications.argoproj.io`: all three apps are **Synced / Healthy**.
- [ ] `migration-waves/` and `vms/` on `main` are empty (run `scripts/reset.sh` otherwise).
- [ ] `oc get vm -n vmimported`: `database`, `winweb01` and `winweb02` are Running. `database` has **1** CPU socket.
- [ ] `route-webapp` in `vmimported` loads, and the URL is copied for the AAP survey.
- [ ] **Failure setup:** in vCenter, **power on `database-user1`**. Part 2 opens on this "mistake".
- [ ] Browser tabs, all logged in:
  1. GitHub repo, **Pull requests** tab
  2. Argo CD: `https://openshift-gitops-server-openshift-gitops.apps.<cluster>/` (Log in via OpenShift)
  3. OpenShift console: **Migration → Plans for virtualization** (project `openshift-mtv`, "Show default projects" on)
  4. AAP: **Templates → VM Migration Wave - Readiness, Approval, Migrate**
  5. vCenter: Workloads → Roadshow folder
  6. OpenShift console: **Virtualization → VirtualMachines** (project `vmimported`)
- [ ] A terminal in the repo directory for the scripts.

---

## 0. Framing (5 min)

**SAY:**
- Most VMware exits stall on coordination rather than technology: spreadsheets of VMs, hand-built migration plans, change tickets, and then servers that drift after cutover.
- Today we'll show a model where:
  - a **migration wave is a pull request**,
  - **automation enforces readiness and approval** before anything moves, and
  - after migration, **VMs are managed the same way**, through Git.
- Three tools, three roles: **Git** says *what*, **Ansible** decides *when* and *whether it's safe*, **OpenShift** does the work.

---

## Part 1: Define the migration with GitOps (12 min)

**SAY:**
- We've got a three-tier app on vSphere: a database and IIS web servers.
- Wave one moves the database and the first web server.
- Instead of clicking through a migration wizard, the migration engineer proposes the wave as code.

**DO:**
```sh
scripts/open-wave-pr.sh wave-01
```
Open the PR in GitHub and walk through the four files:
- `namespace.yaml`: where the VMs land.
- `networkmap.yaml`: the port group `segment-migrating-to-ocpvirt` maps to the OpenShift network.
- `storagemap.yaml`: datastore `workloadshare` maps to Ceph RBD (shared block, so VMs can live-migrate later).
- `plan.yaml`: the two VMs, plus cold migration.

**SAY:**
- This is the same information a VMware admin types into a wizard. Now it's **reviewable**: the app owner, network and storage teams can approve it in one place.
- It's **repeatable**. Wave two is a copy of this folder with different VM names.
- Note the PR description: *merging does not migrate anything.*

**DO:** Approve and merge the PR (or `gh pr merge --squash --delete-branch`).

**DO:** Switch to Argo CD and open **migration-waves**. Click **Refresh** if it hasn't polled yet. Point out:
- the Namespace, NetworkMap, StorageMap and Plan appearing,
- the **Plan going from Progressing to Healthy** while MTV validates it.

**DO:** Switch to the OpenShift console, **Migration → Plans for virtualization**. Plan `wave-01` is shown **Ready**, with the **Start** button available.

**SAY:**
- Argo CD created the migration plan from Git, and MTV validated it against vSphere: the VMs exist, the network and storage are mapped.
- We **won't** press Start here. Who decides *when* a migration runs, and whether it's safe right now, is a process question. That's the job for automation.

> If asked "what if someone edits the plan in the console?": Argo CD shows it OutOfSync and puts it back. Git is the source of truth.

---

## Part 2: Orchestrate the migration with AAP (20 min)

**SAY:** The migration window opens and the operator launches the approved wave from Ansible Automation Platform.

**DO:** In AAP, launch **VM Migration Wave - Readiness, Approval, Migrate**.
- Survey: *Migration wave* = `wave-01`, *Application URL* = the route-webapp URL. Click Launch.
- Open the workflow visualizer and click the **Readiness Checks** node.

**SAY (while it runs):** Before anything moves, Ansible checks:
1. Argo CD has synced exactly what Git approved.
2. MTV has validated the plan, with no blocking issues.
3. This wave hasn't already run.
4. The target namespace and storage exist.
5. **The source VMs are powered off in vCenter.** Change policy says app owners shut down their own servers.

**DO:** The node **fails**. Open the job output and scroll to the **Readiness report**:
```
FAIL  vSphere VM database-user1 is POWERED ON - the app owner must shut it down before the migration window
```

**SAY:**
- Nothing was migrated and nobody was paged at 2 AM. The workflow stopped *before* the approval step, so an approver never sees a wave that isn't ready.
- The PASS lines show everything else is good.

**DO:** In vCenter, **power off `database-user1`** and wait until it reads Powered Off. Then relaunch the workflow with the same survey values.

**DO:** Readiness now passes, and the workflow pauses at **Approve migration wave**. Show the approval in AAP's **Workflow Approvals** (the bell/notification icon) and click **Approve**.

**SAY:**
- The approval is a recorded decision: who approved, when, for which Git revision.
- Approvers can be a CAB group in AAP RBAC.
- The same gate can be driven from ServiceNow.

**DO:**
- After approval, open **2 Start Migration**. It shows the `Migration` object created (named `wave-01-<timestamp>`).
- Then open **3 Monitor Migration** and show the per-VM progress lines (`database-user1: Running - DiskTransfer 12%`).
- Optionally switch to the OpenShift console, **Plans for virtualization → wave-01**, and show the same progress there.

**SAY:**
- Ansible started the migration only after checks and approval, and it's following it.
- The disks are around 100 GB, so rather than watch the copy, we'll validate VMs that went through this same process earlier.

**DO:** In AAP, launch the job template **VM Migration - 4 Validate VMs** with these extra vars:
```yaml
validate_namespace: vmimported
validate_vms: [database, winweb01, winweb02]
start_vms: false
app_url: http://route-webapp-vmimported.apps.<cluster>/
```
Show the **Health report**: Running/Ready, node, IP, guest agent, vCPU and memory, and the app's HTTP 200. Open the app URL in a browser and show the visitor counter.

**SAY:**
- The same validation runs as the last step of the workflow.
- AAP gives one record per wave: readiness evidence, approver, execution, and health validation.

> **Potential:** the workflow's failure path can open a ticket, notify Slack or Teams, or roll back DNS. These are standard AAP integrations.

---

## Part 3: Manage the VM lifecycle with GitOps (15 min)

**SAY:**
- The migration is done. In most shops, this is where VMs go back to tickets and console clicks, and drift starts.
- Let's put the migrated database server under Git management, **without restarting it**.

**DO:**
```sh
scripts/adopt-vm.sh vmimported database
```
Open the PR and point out:
- the VM definition exported from the running VM,
- `Prune=false,Delete=false`: deleting this file can never delete the VM,
- CPU `sockets: 1` and memory `2Gi`.

**DO:** Merge. In Argo CD, open **vm-lifecycle**. `database` appears **Synced / Healthy**. In the console, show the VM still running with the same uptime.

**SAY:** Argo CD adopted the existing VM in place. From now on, the VM's configuration lives in Git.

**DO:**
```sh
scripts/resize-vm-pr.sh vmimported database 2
```
Show the PR: a **one-line diff**, `sockets: 1` → `sockets: 2`. Merge it.

**DO:** In Argo CD, `database` syncs. In the OpenShift console, open **Virtualization → VirtualMachines → database**:
- **Overview**: CPU now shows **2**.
- **Events** or the **Migrations** tab: a live migration ran to hot-plug the CPU.
- **Optional:** open the console tab and run `nproc` to show **2**. *No reboot.*

**SAY:**
- A capacity change went through peer review, has an audit trail in Git, and was applied with **zero downtime**.
- To roll back, revert the PR.

**DO (drift, optional, 2 min):** In the OpenShift console, edit `database` and set CPU to 3 sockets. Save. Watch Argo CD show it OutOfSync and then **put it back to 2** (self-heal).

**SAY:** Configuration drift is corrected automatically. The only way to change a managed VM is through Git.

---

## Recap (3 min)

**SAY:** You've seen that you can:
1. **Define and approve migrations declaratively.** A wave is a PR, and Argo CD builds the MTV plan.
2. **Execute migrations through a repeatable, controlled workflow.** AAP checks readiness, blocks unsafe runs, gates on approval, executes and validates.
3. **Manage migrated VMs through Git.** VMs are adopted in place, changed by PR, applied live, and kept from drifting.

The business outcomes:
- less engineering effort per wave,
- a faster and more predictable VMware exit,
- less drift and maintenance after cutover.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Argo app OutOfSync, nothing appears after merge | Argo polls every ~3 min. Click **Refresh** on the app, or `oc -n openshift-gitops annotate applications.argoproj.io migration-waves argocd.argoproj.io/refresh=hard --overwrite` |
| Plan stuck Progressing in Argo | Look at the Plan's conditions in the OpenShift console (Migration → Plans → wave-01 → conditions). The VDDK image validation can take a few minutes. |
| Readiness check 7 errors connecting to vCenter | Check the AAP credential **VMware Credentials** (host, user1). As a last resort, launch with extra var `check_vsphere_power_state: false`. |
| "Wave has already been migrated" | Each vSphere VM migrates once per lab. Use `wave-00-rehearsal`, or `scripts/reset.sh --vms`. |
| CPU change shows "RestartRequired" instead of applying live | The VM is not live-migratable or has hit `maxSockets`. Check `oc get vmi database -n vmimported -o jsonpath='{.spec.domain.cpu.maxSockets}'` (expected 4). |
