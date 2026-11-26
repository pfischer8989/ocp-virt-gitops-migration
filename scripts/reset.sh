#!/usr/bin/env bash
# Reset the demo between rehearsals / deliveries.
#
#   scripts/reset.sh            # remove waves + adopted VMs from Git, clean MTV objects
#   scripts/reset.sh --vms      # ALSO delete migrated VMs in vm-wave-* namespaces
#
# Note: a vSphere VM can only be migrated once per lab environment (MAC
# addresses would collide). Deleting migrated VMs lets you re-run a wave.
# Adopted VMs (e.g. vmimported/database) are never deleted - only released
# from Git. Their CPU is NOT reverted automatically; use resize-vm-pr.sh first
# if you want to restore it.
source "$(dirname "$0")/lib.sh"
DELETE_VMS=false; [[ "${1:-}" == "--vms" ]] && DELETE_VMS=true
require_oc_login
require_clean_main
cd "$REPO_ROOT"

echo "This will:"
echo "  - push a commit to $REPO_BRANCH removing migration-waves/* and vms/*"
echo "  - delete MTV Migrations for waves in $MTV_NAMESPACE"
$DELETE_VMS && echo "  - DELETE namespaces vm-wave-* and every VM in them"
read -r -p "Continue? [y/N] " a; [[ "$a" == [yY] ]] || exit 1

shopt -s nullglob
for d in migration-waves/*/ vms/*/; do git rm -rq -- "$d"; done
shopt -u nullglob
if ! git diff --cached --quiet; then
  git commit -q -m "demo: reset migration waves and adopted VMs"
  git push -q origin "$REPO_BRANCH"
  ok "Git reset pushed"
fi

oc delete migration.forklift.konveyor.io -n "$MTV_NAMESPACE" -l migration-wave --ignore-not-found
# Plans/maps are pruned by Argo CD; delete directly so reset doesn't wait on sync.
oc delete plan.forklift.konveyor.io,networkmap.forklift.konveyor.io,storagemap.forklift.konveyor.io \
  -n "$MTV_NAMESPACE" -l migration-wave --ignore-not-found

# Release adopted VMs from Argo tracking (they stay running).
for vm in $(oc get vm -A -l app.kubernetes.io/managed-by=argocd -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}'); do
  oc label vm -n "${vm%/*}" "${vm#*/}" app.kubernetes.io/managed-by- app.kubernetes.io/instance- >/dev/null
  oc annotate vm -n "${vm%/*}" "${vm#*/}" argocd.argoproj.io/sync-options- argocd.argoproj.io/tracking-id- gitops/adopted-from- >/dev/null
  ok "released $vm from GitOps"
done

if $DELETE_VMS; then
  for ns in $(oc get ns -l migration-wave -o name); do
    oc delete "$ns" --wait=false
  done
fi
ok "reset complete"
