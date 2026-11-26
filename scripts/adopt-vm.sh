#!/usr/bin/env bash
# Part 3: adopt a running (migrated) VM into GitOps management.
#
#   scripts/adopt-vm.sh vmimported database
#
# Exports the live VirtualMachine, strips runtime/generated fields, marks it so
# Argo CD can never prune or delete it, and opens a PR adding
# vms/<namespace>/<name>.yaml. After merge, Argo CD adopts the existing VM in
# place (server-side apply) - no restart, no re-creation.
source "$(dirname "$0")/lib.sh"
NS=${1:?usage: adopt-vm.sh <namespace> <vm>}
VM=${2:?usage: adopt-vm.sh <namespace> <vm>}
require_oc_login
require_clean_main
OUT="$REPO_ROOT/vms/$NS/$VM.yaml"
[[ -e "$OUT" ]] && die "vms/$NS/$VM.yaml already exists - VM is already under GitOps"
mkdir -p "$(dirname "$OUT")"

oc get vm "$VM" -n "$NS" -o json | python3 -c '
import json, sys, yaml

vm = json.load(sys.stdin)
md = vm["metadata"]

DROP_ANN_PREFIXES = ("kubevirt.io/latest-observed-api-version",
                     "kubevirt.io/storage-observed-api-version",
                     "kubectl.kubernetes.io/last-applied-configuration",
                     "argocd.argoproj.io/tracking-id")
ann = {k: v for k, v in (md.get("annotations") or {}).items()
       if not k.startswith(DROP_ANN_PREFIXES)}
ann["argocd.argoproj.io/sync-options"] = "Prune=false,Delete=false"
ann["gitops/adopted-from"] = "mtv-migration"

labels = {k: v for k, v in (md.get("labels") or {}).items()
          if k != "app.kubernetes.io/instance"}
labels["app.kubernetes.io/managed-by"] = "argocd"

spec = vm["spec"]
tmpl_md = spec.get("template", {}).get("metadata", {})
tmpl_md.pop("creationTimestamp", None)
for dvt in spec.get("dataVolumeTemplates", []):
    dvt.get("metadata", {}).pop("creationTimestamp", None)

out = {
    "apiVersion": vm["apiVersion"],
    "kind": vm["kind"],
    "metadata": {"name": md["name"], "namespace": md["namespace"],
                 "labels": labels, "annotations": ann},
    "spec": spec,
}

class Dumper(yaml.SafeDumper):
    pass
Dumper.add_representer(str, lambda d, s: d.represent_scalar(
    "tag:yaml.org,2002:str", s, style="|" if "\n" in s else None))

print("# Adopted into GitOps from a running VM (scripts/adopt-vm.sh).")
print("# Edit via pull request only - Argo CD reverts manual changes (selfHeal).")
print("# CPU: spec.template.spec.domain.cpu.sockets is hot-pluggable (LiveUpdate).")
yaml.dump(out, sys.stdout, Dumper=Dumper, sort_keys=False, default_flow_style=False)
' > "$OUT"

oc apply --server-side --force-conflicts --field-manager=argocd-controller --dry-run=server -f "$OUT" >/dev/null || die "exported manifest failed server-side validation"
ok "exported vms/$NS/$VM.yaml"

CPU=$(oc get vm "$VM" -n "$NS" -o jsonpath='{.spec.template.spec.domain.cpu.sockets}')
open_pr "adopt/$NS-$VM" "Adopt VM $NS/$VM into GitOps" "$(cat <<MD
Brings the migrated VM \`$NS/$VM\` under Git management.

- Exported from the running VM; runtime fields stripped.
- Argo CD adopts the **existing** VM in place - no restart, no re-creation.
- \`Prune=false,Delete=false\`: removing this file can never delete the VM.
- From now on, configuration changes to this VM go through pull requests;
  manual changes are reverted by Argo CD.

Current CPU sockets: **$CPU**
MD
)" "vms/$NS/$VM.yaml"
