#!/usr/bin/env bash
# Configure Ansible Automation Platform for Part 2 of the demo:
#   project (this repo) -> 4 job templates -> 1 workflow with an approval gate
#
#   [1 Readiness checks] --ok--> [Approval] --approved--> [2 Start migration]
#        --ok--> [3 Monitor migration] --ok--> [4 Validate VMs]
#
# Reuses the "kubeconfig" and "VMware Credentials" credentials that the lab
# install already created. Idempotent - safe to re-run (workflow nodes are
# rebuilt each time).
source "$(dirname "$0")/lib.sh"
need curl jq
require_oc_login

AAP_HOST=$(oc get route "$AAP_ROUTE" -n "$AAP_NAMESPACE" -o jsonpath='{.spec.host}')
AAP_PASS=$(oc get secret "$AAP_ADMIN_PASSWORD_SECRET" -n "$AAP_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
API="https://$AAP_HOST/api/controller/v2"

PROJECT_NAME="VM Migration GitOps"
INVENTORY_NAME="VM Migration - localhost"
WORKFLOW_NAME="VM Migration Wave - Readiness, Approval, Migrate"

# api METHOD PATH [JSON]  -> prints response body, dies on HTTP >= 400
api() {
  local method=$1 path=$2 data=${3:-}
  local out code
  out=$(mktemp)
  code=$(curl -sk -o "$out" -w '%{http_code}' -u "$AAP_ADMIN_USER:$AAP_PASS" \
           -X "$method" -H 'Content-Type: application/json' \
           ${data:+-d "$data"} "$API$path")
  if (( code >= 400 )); then
    cat "$out" >&2; rm -f "$out"
    die "AAP API $method $path -> HTTP $code"
  fi
  cat "$out"; rm -f "$out"
}

# id_of ENDPOINT NAME [EXTRA_QUERY]  -> id or empty
id_of() {
  api GET "/$1/?name=$(jq -rn --arg n "$2" '$n|@uri')${3:+&$3}" | jq -r '.results[0].id // empty'
}

# upsert ENDPOINT NAME JSON -> id
upsert() {
  local ep=$1 name=$2 body=$3 id
  body=$(jq -c --arg n "$name" '. + {name: $n}' <<<"$body")
  id=$(id_of "$ep" "$name")
  if [[ -n "$id" ]]; then
    api PATCH "/$ep/$id/" "$body" >/dev/null
  else
    id=$(api POST "/$ep/" "$body" | jq -r .id)
  fi
  echo "$id"
}

attach_credential() { # JT_ID CRED_ID
  local have
  have=$(api GET "/job_templates/$1/credentials/" | jq --argjson c "$2" '[.results[].id] | index($c)')
  [[ "$have" == "null" ]] && api POST "/job_templates/$1/credentials/" "{\"id\": $2}" >/dev/null
  return 0
}

info "AAP: https://$AAP_HOST"
ORG_ID=$(id_of organizations "$AAP_ORG"); [[ -n "$ORG_ID" ]] || die "organization '$AAP_ORG' not found"
KUBE_CRED=$(id_of credentials "$AAP_KUBE_CREDENTIAL");     [[ -n "$KUBE_CRED" ]] || die "credential '$AAP_KUBE_CREDENTIAL' not found"
VMW_CRED=$(id_of credentials "$AAP_VMWARE_CREDENTIAL");    [[ -n "$VMW_CRED" ]]  || die "credential '$AAP_VMWARE_CREDENTIAL' not found"
ok "org=$ORG_ID kubeconfig-cred=$KUBE_CRED vmware-cred=$VMW_CRED"

# Collections in collections/requirements.yml are installed from Galaxy on
# project sync; make sure the org has a Galaxy credential.
if [[ $(api GET "/organizations/$ORG_ID/galaxy_credentials/" | jq '.count') == 0 ]]; then
  GALAXY=$(id_of credentials "Ansible Galaxy")
  [[ -n "$GALAXY" ]] && api POST "/organizations/$ORG_ID/galaxy_credentials/" "{\"id\": $GALAXY}" >/dev/null \
    && ok "attached Ansible Galaxy credential to org"
fi

SCM_CRED=null
if [[ -n "${REPO_TOKEN:-}" ]]; then
  SCM_TYPE=$(id_of credential_types "Source Control")
  SCM_CRED=$(upsert credentials "GitHub - ocp-virt-gitops-migration" \
    "$(jq -n --argjson o "$ORG_ID" --argjson t "$SCM_TYPE" --arg p "$REPO_TOKEN" \
        '{organization:$o, credential_type:$t, inputs:{username:"git", password:$p}}')")
  ok "SCM credential $SCM_CRED"
fi

info "Project: $PROJECT_NAME -> $REPO_URL ($REPO_BRANCH)"
PROJECT_ID=$(upsert projects "$PROJECT_NAME" "$(jq -n --argjson o "$ORG_ID" --arg u "$REPO_URL" \
  --arg b "$REPO_BRANCH" --argjson c "$SCM_CRED" \
  '{organization:$o, scm_type:"git", scm_url:$u, scm_branch:$b, credential:$c,
    scm_update_on_launch:true, scm_clean:true,
    description:"Readiness checks, approval-gated execution and validation for GitOps-defined MTV migration waves"}')")
UPDATE_ID=$(api POST "/projects/$PROJECT_ID/update/" '{}' | jq -r '.project_update')
for _ in $(seq 1 60); do
  STATUS=$(api GET "/project_updates/$UPDATE_ID/" | jq -r .status)
  [[ "$STATUS" =~ ^(successful|failed|error|canceled)$ ]] && break
  sleep 5
done
[[ "$STATUS" == successful ]] || die "project sync $STATUS - see https://$AAP_HOST/execution/jobs/project/$UPDATE_ID/output"
ok "project $PROJECT_ID synced"

info "Inventory: $INVENTORY_NAME"
INV_ID=$(upsert inventories "$INVENTORY_NAME" "{\"organization\": $ORG_ID}")
HOST_VARS=$'ansible_connection: local\nansible_python_interpreter: "{{ ansible_playbook_python }}"'
HOST_ID=$(api GET "/inventories/$INV_ID/hosts/?name=localhost" | jq -r '.results[0].id // empty')
HOST_BODY=$(jq -n --arg v "$HOST_VARS" --argjson i "$INV_ID" '{name:"localhost", inventory:$i, variables:$v}')
if [[ -n "$HOST_ID" ]]; then api PATCH "/hosts/$HOST_ID/" "$HOST_BODY" >/dev/null
else api POST "/hosts/" "$HOST_BODY" >/dev/null; fi
ok "inventory $INV_ID"

jt() { # NAME PLAYBOOK DESCRIPTION CRED_IDS...
  local name=$1 playbook=$2 desc=$3; shift 3
  local id
  id=$(upsert job_templates "$name" "$(jq -n --argjson p "$PROJECT_ID" --argjson i "$INV_ID" \
    --arg pb "$playbook" --arg d "$desc" \
    '{project:$p, inventory:$i, playbook:$pb, description:$d, job_type:"run",
      ask_variables_on_launch:true, verbosity:0}')")
  for c in "$@"; do attach_credential "$id" "$c"; done
  echo "$id"
}

info "Job templates"
JT_READY=$(jt "VM Migration - 1 Readiness Checks"  ansible/readiness-check.yml \
  "GitOps sync, MTV plan validation, target capacity, vSphere power state" "$KUBE_CRED" "$VMW_CRED")
JT_START=$(jt "VM Migration - 2 Start Migration"   ansible/start-migration.yml \
  "Create the MTV Migration for an approved, Git-defined plan" "$KUBE_CRED")
JT_MON=$(jt   "VM Migration - 3 Monitor Migration" ansible/monitor-migration.yml \
  "Follow per-VM migration progress until completion" "$KUBE_CRED")
JT_VAL=$(jt   "VM Migration - 4 Validate VMs"      ansible/validate-vms.yml \
  "Start migrated VMs and validate health + application" "$KUBE_CRED")
ok "templates $JT_READY $JT_START $JT_MON $JT_VAL"

info "Workflow: $WORKFLOW_NAME"
WF_ID=$(upsert workflow_job_templates "$WORKFLOW_NAME" "$(jq -n --argjson o "$ORG_ID" --argjson i "$INV_ID" \
  '{organization:$o, inventory:$i, survey_enabled:true, allow_simultaneous:false,
    description:"Approved Git migration wave -> readiness checks -> human approval -> MTV execution -> validation"}')")

api POST "/workflow_job_templates/$WF_ID/survey_spec/" "$(jq -n '{
  name: "Migration wave", description: "Which Git-defined migration wave to execute",
  spec: [
    {question_name: "Migration wave (MTV plan name)", variable: "plan_name", type: "text",
     required: true, default: "wave-01", min: 1, max: 63,
     question_description: "Name of the Plan merged under migration-waves/ in Git"},
    {question_name: "Application URL to validate (optional)", variable: "app_url", type: "text",
     required: false, default: "", min: 0, max: 512,
     question_description: "HTTP endpoint that must return 200 after migration"}
  ]}')" >/dev/null

# Rebuild the graph from scratch so re-runs never duplicate nodes.
for nid in $(api GET "/workflow_job_templates/$WF_ID/workflow_nodes/?page_size=100" | jq -r '.results[].id'); do
  api DELETE "/workflow_job_template_nodes/$nid/" >/dev/null
done
node() { # UJT_ID IDENTIFIER
  api POST "/workflow_job_templates/$WF_ID/workflow_nodes/" \
    "$(jq -n --argjson u "$1" --arg id "$2" '{unified_job_template:$u, identifier:$id}')" | jq -r .id
}
N_READY=$(node "$JT_READY" readiness)
N_APPROVE=$(api POST "/workflow_job_templates/$WF_ID/workflow_nodes/" '{"identifier":"approval"}' | jq -r .id)
api POST "/workflow_job_template_nodes/$N_APPROVE/create_approval_template/" \
  '{"name":"Approve migration wave","description":"Readiness checks passed. Approve to start the MTV migration (source VMs will be cut over).","timeout":0}' >/dev/null
N_START=$(node "$JT_START" start)
N_MON=$(node "$JT_MON" monitor)
N_VAL=$(node "$JT_VAL" validate)
link() { api POST "/workflow_job_template_nodes/$1/success_nodes/" "{\"id\": $2}" >/dev/null; }
link "$N_READY" "$N_APPROVE"
link "$N_APPROVE" "$N_START"
link "$N_START" "$N_MON"
link "$N_MON" "$N_VAL"
ok "workflow $WF_ID: readiness -> approval -> start -> monitor -> validate"

echo
ok "Launch it: https://$AAP_HOST/execution/templates/workflow-job-template/$WF_ID/details"
