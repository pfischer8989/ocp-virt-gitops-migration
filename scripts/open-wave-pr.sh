#!/usr/bin/env bash
# Part 1: open a PR that adds a migration wave under migration-waves/.
#
#   scripts/open-wave-pr.sh wave-01             # the demo wave
#   scripts/open-wave-pr.sh wave-00-rehearsal   # burnable rehearsal wave (haproxy)
#
# Merging the PR is the approval. Argo CD then syncs the Namespace, NetworkMap,
# StorageMap and Plan; MTV validates the Plan. Nothing migrates yet.
source "$(dirname "$0")/lib.sh"
WAVE=${1:-wave-01}
SRC="$REPO_ROOT/examples/$WAVE"
DST="$REPO_ROOT/migration-waves/$WAVE"
[[ -d "$SRC" ]] || die "no such example wave: examples/$WAVE"
require_clean_main
[[ -e "$DST" ]] && die "migration-waves/$WAVE already exists on $REPO_BRANCH"

mkdir -p "$DST"
cp "$SRC"/*.yaml "$DST/"
VMS=$(python3 -c 'import sys,yaml;print("\n".join("- `"+v["name"]+"`" for v in yaml.safe_load(open(sys.argv[1]))["spec"]["vms"]))' "$DST/plan.yaml")
TARGET=$(python3 -c 'import sys,yaml;print(yaml.safe_load(open(sys.argv[1]))["spec"]["targetNamespace"])' "$DST/plan.yaml")

open_pr "migration/$WAVE" "Migration wave: $WAVE" "$(cat <<MD
## Migration wave \`$WAVE\`

| | |
|---|---|
| Source | vSphere provider \`vmware\` |
| Target | OpenShift Virtualization, namespace \`$TARGET\` |
| Network | \`segment-migrating-to-ocpvirt\` -> pod network |
| Storage | \`workloadshare\` -> \`ocs-external-storagecluster-ceph-rbd\` (RWX block) |
| Type | Cold migration |

### VMs
$VMS

### What merging does
Argo CD syncs the MTV **Plan**, **NetworkMap** and **StorageMap** and MTV validates them.
**No VM is migrated on merge.** Execution happens in the AAP workflow
*VM Migration Wave - Readiness, Approval, Migrate* after readiness checks and approval.
MD
)" "migration-waves/$WAVE"
