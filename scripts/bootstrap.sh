#!/usr/bin/env bash
# One-time cluster setup: install OpenShift GitOps, teach Argo CD how to judge
# MTV object health, then hand control to the app-of-apps in apps/.
#
# Idempotent - safe to re-run.
source "$(dirname "$0")/lib.sh"
require_oc_login

info "Installing the OpenShift GitOps operator"
oc apply -k "$REPO_ROOT/bootstrap/gitops-operator"
wait_for "GitOps operator installed" 600 \
  bash -c "oc get csv -n openshift-gitops-operator -o jsonpath='{.items[*].status.phase}' | grep -q Succeeded"
wait_for "default Argo CD instance created" 600 \
  oc get argocd openshift-gitops -n "$GITOPS_NAMESPACE"
wait_for "Argo CD server ready" 600 \
  oc rollout status deploy/openshift-gitops-server -n "$GITOPS_NAMESPACE" --timeout=5s

info "Adding health checks for MTV Plan / NetworkMap / StorageMap"
# Without these, Argo shows MTV objects as Healthy the instant they exist.
# With them, a Plan shows Progressing while MTV validates it, Healthy when
# Ready, and Degraded on a Critical/Error condition - visible in the Argo UI.
read -r -d '' MTV_HEALTH <<'LUA' || true
hs = {}
if obj.status ~= nil and obj.status.conditions ~= nil then
  for _, c in ipairs(obj.status.conditions) do
    if c.status == "True" and (c.category == "Critical" or c.category == "Error") then
      hs.status = "Degraded"
      hs.message = c.message
      return hs
    end
  end
  for _, c in ipairs(obj.status.conditions) do
    if c.type == "Succeeded" and c.status == "True" then
      hs.status = "Healthy"
      hs.message = "Migration completed"
      return hs
    end
  end
  for _, c in ipairs(obj.status.conditions) do
    if c.type == "Ready" and c.status == "True" then
      hs.status = "Healthy"
      hs.message = c.message
      return hs
    end
  end
end
hs.status = "Progressing"
hs.message = "Waiting for MTV to validate"
return hs
LUA
patch=$(jq -n --arg lua "$MTV_HEALTH" '{spec: {
  resourceHealthChecks: [
    {group: "forklift.konveyor.io", kind: "Plan",       check: $lua},
    {group: "forklift.konveyor.io", kind: "NetworkMap", check: $lua},
    {group: "forklift.konveyor.io", kind: "StorageMap", check: $lua}
  ],
  rbac: {
    defaultPolicy: "",
    scopes: "[groups, name, preferred_username]",
    policy: "g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\ng, admin, role:admin\n"
  }
}}')
oc patch argocd openshift-gitops -n "$GITOPS_NAMESPACE" --type merge -p "$patch" >/dev/null
ok "health checks + RBAC configured (OpenShift user 'admin' is an Argo CD admin)"

if [[ -n "${REPO_TOKEN:-}" ]]; then
  info "Creating Argo CD repository secret (private repo)"
  oc create secret generic ocp-virt-gitops-migration-repo -n "$GITOPS_NAMESPACE" \
    --from-literal=type=git --from-literal=url="$REPO_URL" \
    --from-literal=username=git --from-literal=password="$REPO_TOKEN" \
    --dry-run=client -o yaml \
    | oc label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | oc apply -f - >/dev/null
  ok "repo secret applied"
fi

info "Applying AppProject, RBAC and the root app-of-apps"
oc apply -k "$REPO_ROOT/bootstrap"
wait_for "child applications created" 300 \
  bash -c "oc get application migration-waves vm-lifecycle -n $GITOPS_NAMESPACE"

echo
oc get applications -n "$GITOPS_NAMESPACE"
echo
ok "Argo CD UI: https://$(oc get route openshift-gitops-server -n "$GITOPS_NAMESPACE" -o jsonpath='{.spec.host}')"
echo "   Log in with OpenShift credentials (admin)."
