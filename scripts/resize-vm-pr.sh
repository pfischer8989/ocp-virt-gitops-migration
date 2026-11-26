#!/usr/bin/env bash
# Part 3: change a GitOps-managed VM's CPU through a PR.
#
#   scripts/resize-vm-pr.sh vmimported database 2     # set CPU sockets to 2
#
# With the cluster's LiveUpdate rollout strategy and RWX storage, KubeVirt
# hot-plugs the new vCPUs via a live migration - the VM keeps running.
source "$(dirname "$0")/lib.sh"
NS=${1:?usage: resize-vm-pr.sh <namespace> <vm> <sockets>}
VM=${2:?usage: resize-vm-pr.sh <namespace> <vm> <sockets>}
SOCKETS=${3:?usage: resize-vm-pr.sh <namespace> <vm> <sockets>}
require_clean_main
FILE="vms/$NS/$VM.yaml"
[[ -f "$REPO_ROOT/$FILE" ]] || die "$FILE not found - adopt the VM first (scripts/adopt-vm.sh $NS $VM)"

OLD=$(python3 - "$REPO_ROOT/$FILE" "$SOCKETS" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
text = open(path).read()
# Edit in place with a regex so the PR diff is exactly one line.
m = re.search(r'(\n(\s+)cpu:\n(?:\2\s+.*\n)*?\2\s+sockets: )(\d+)', text)
if not m:
    sys.exit("could not find spec.template.spec.domain.cpu.sockets")
old = m.group(3)
text = text[:m.start(3)] + new + text[m.end(3):]
open(path, "w").write(text)
print(old)
PY
)
[[ "$OLD" == "$SOCKETS" ]] && { git -C "$REPO_ROOT" checkout -q -- "$FILE"; die "VM already has $SOCKETS sockets"; }
git -C "$REPO_ROOT" --no-pager diff -- "$FILE"

open_pr "resize/$NS-$VM-cpu-$SOCKETS" "Resize $NS/$VM: CPU sockets $OLD -> $SOCKETS" "$(cat <<MD
Scale \`$NS/$VM\` from **$OLD** to **$SOCKETS** vCPU sockets.

On merge, Argo CD applies the change and OpenShift Virtualization hot-plugs the
CPUs (LiveUpdate rollout via live migration) - **no reboot, no downtime**.
MD
)" "$FILE"
