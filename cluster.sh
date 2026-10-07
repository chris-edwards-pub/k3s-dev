#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in --query strings are JMESPath literals, not shell
# Manage the k3s-dev cluster: start/stop/destroy it and keep ./kubeconfig current.
set -euo pipefail

cd "$(dirname "$0")"
KUBECONFIG_FILE="$PWD/kubeconfig"
WAIT_TIMEOUT=600 # seconds to wait for the server to publish its kubeconfig

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [terraform args...]

Commands:
  up         start stopped nodes, terraform apply (creates the cluster if needed),
             then fetch the kubeconfig and wait for all nodes to be Ready
  down       stop all nodes to save cost (EBS + Elastic IP still billed, ~\$9/mo)
  destroy    terraform destroy, then remove the kubeconfig (local + SSM)
  refresh    rebuild the kubeconfig from the live server, update SSM + local file
  kubeconfig fetch the kubeconfig from SSM (waits if the server is still bootstrapping)
  status     show instance states, IPs, and nodes

Extra args are passed to terraform for up/destroy (e.g. -auto-approve).
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=() tool
  for tool in terraform aws kubectl python3 ssh; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
}

# Read a simple `name = "value"` string from terraform.tfvars
tfvar() {
  [[ -f terraform.tfvars ]] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" terraform.tfvars | tail -1
}

# The S3 backend can't use variables, so pass the private bucket from terraform.tfvars
# at init time. Re-inits when .terraform points at a different bucket, or when Terraform
# can't read state (fresh clone, or the backend block changed).
ensure_init() {
  local bucket region
  bucket=$(tfvar state_bucket)
  region=$(tfvar state_region)
  region=${region:-us-east-1}
  [[ -n "$bucket" ]] ||
    die "state_bucket not set; cp terraform.tfvars.example terraform.tfvars and fill it in"
  if ! grep -q "\"bucket\": *\"$bucket\"" .terraform/terraform.tfstate 2>/dev/null ||
    ! terraform output -json >/dev/null 2>&1; then
    log "terraform init (state: s3://$bucket)"
    terraform init -input=false -reconfigure \
      -backend-config="bucket=$bucket" -backend-config="region=$region" >/dev/null
  fi
}

tf_out() { terraform output -raw "$1" 2>/dev/null; }

# After a destroy, `terraform output` still exits 0 but prints nothing, so test for a value
has_cluster() { [[ -n "$(tf_out server_instance_id || true)" ]]; }

load_outputs() {
  has_cluster || die "no cluster in state; run '$0 up' first"
  CLUSTER_NAME=$(tf_out cluster_name)
  REGION=$(tf_out region)
  SERVER_ID=$(tf_out server_instance_id)
  SERVER_IP=$(tf_out server_public_ip)
  PARAM="/$CLUSTER_NAME/kubeconfig"
  # shellcheck disable=SC2207
  INSTANCE_IDS=($(terraform output -json nodes | python3 -c 'import json,sys; print(" ".join(n["id"] for n in json.load(sys.stdin).values()))'))
}

instance_states() {
  aws ec2 describe-instances --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name]' --output text | sort
}

# After a user stop, a persistent Spot request sits in "marked-for-stop" for ~3 min and
# StartInstances fails until it reaches "disabled". Wait for that (no-op for on-demand).
wait_spot_startable() {
  local deadline pending
  deadline=$(($(date +%s) + WAIT_TIMEOUT))
  while :; do
    pending=$(aws ec2 describe-spot-instance-requests --region "$REGION" \
      --filters "Name=instance-id,Values=$(IFS=,; echo "${INSTANCE_IDS[*]}")" \
      --query 'length(SpotInstanceRequests[?State!=`disabled` && Status.Code!=`fulfilled`])' --output text)
    ((pending == 0)) && return
    (($(date +%s) < deadline)) || die "Spot requests still not startable after ${WAIT_TIMEOUT}s"
    log "waiting for $pending Spot request(s) to finish stopping (takes ~3 min after 'down')"
    sleep 15
  done
}

# Epoch seconds from an ISO-8601 timestamp (portable across macOS/Linux)
to_epoch() {
  python3 -c 'import sys, datetime; print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))' "$1"
}

write_kubeconfig() {
  umask 077
  cat >"$KUBECONFIG_FILE"
  log "wrote $KUBECONFIG_FILE"
}

# Fetch the kubeconfig from SSM, waiting until it was published by the current server so a
# stale copy is never used. Compares against the primary ENI attach time, which is fixed at
# instance creation (LaunchTime resets on every stop/start).
fetch_kubeconfig() {
  load_outputs
  local created modified deadline
  created=$(to_epoch "$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SERVER_ID" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`0`]|[0].Attachment.AttachTime' \
    --output text)")
  deadline=$(($(date +%s) + WAIT_TIMEOUT))

  log "waiting for $PARAM from server $SERVER_ID"
  while :; do
    modified=$(aws ssm get-parameter --region "$REGION" --name "$PARAM" \
      --query Parameter.LastModifiedDate --output text 2>/dev/null || true)
    if [[ -n "$modified" && "$modified" != "None" ]] && (($(to_epoch "$modified") >= created)); then
      break
    fi
    (($(date +%s) < deadline)) || die "timed out; check /var/log/k3s-bootstrap.log on the server"
    sleep 10
  done

  aws ssm get-parameter --region "$REGION" --name "$PARAM" --with-decryption \
    --query Parameter.Value --output text | write_kubeconfig
}

# Rebuild the kubeconfig straight from the server (e.g. after k3s rotated its certs)
refresh_kubeconfig() {
  load_outputs
  local tmp
  tmp=$(mktemp)

  log "reading /etc/rancher/k3s/k3s.yaml from ec2-user@$SERVER_IP"
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "ec2-user@$SERVER_IP" \
    cat /etc/rancher/k3s/k3s.yaml |
    sed -e "s/127.0.0.1/$SERVER_IP/" -e "s/: default\$/: $CLUSTER_NAME/" >"$tmp"
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "empty kubeconfig from server"; }

  log "updating SSM parameter $PARAM"
  aws ssm put-parameter --region "$REGION" --name "$PARAM" \
    --type SecureString --tier Intelligent-Tiering --overwrite \
    --value "file://$tmp" >/dev/null
  write_kubeconfig <"$tmp"
  rm -f "$tmp"
}

wait_for_nodes() {
  local want deadline ready
  want=$(terraform output -json nodes | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  deadline=$(($(date +%s) + WAIT_TIMEOUT))
  log "waiting for $want nodes to be Ready"
  while :; do
    ready=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
    ((ready >= want)) && break
    (($(date +%s) < deadline)) || die "only $ready/$want nodes Ready after ${WAIT_TIMEOUT}s"
    sleep 10
  done
  KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes -o wide
}

cmd_up() {
  if has_cluster; then
    load_outputs
    wait_spot_startable
    log "starting nodes"
    aws ec2 start-instances --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
    aws ec2 wait instance-running --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}"
  fi
  # Also refreshes agent public IPs (they change on start) and the admin IP rule
  terraform apply "$@"
  fetch_kubeconfig
  wait_for_nodes
  log "done: export KUBECONFIG=$KUBECONFIG_FILE"
}

cmd_down() {
  load_outputs
  log "stopping nodes"
  aws ec2 stop-instances --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
  aws ec2 wait instance-stopped --region "$REGION" --instance-ids "${INSTANCE_IDS[@]}"
  instance_states
  log "stopped; run '$0 up' to start again"
}

cmd_destroy() {
  if has_cluster; then load_outputs; fi
  terraform destroy "$@"
  if [[ -n "${PARAM:-}" ]]; then
    aws ssm delete-parameter --region "$REGION" --name "$PARAM" 2>/dev/null &&
      log "deleted SSM parameter $PARAM" || true
  fi
  rm -f "$KUBECONFIG_FILE"
  log "removed $KUBECONFIG_FILE"
}

cmd_status() {
  load_outputs
  instance_states
  terraform output nodes
  terraform output -json auto_stop 2>/dev/null | python3 -c '
import json, sys
a = json.load(sys.stdin)
print("auto-stop: %s %s (%s)" % (a["schedule"], a["timezone"], a["function"]) if a else "auto-stop: disabled")' >&2 || true
  if ! instance_states | grep -q 'running$'; then
    log "nodes are not running; run '$0 up'"
  elif [[ -f "$KUBECONFIG_FILE" ]]; then
    KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes -o wide
  else
    log "no kubeconfig yet; run '$0 kubeconfig'"
  fi
}

case "${1:-}" in
  up | down | destroy | refresh | kubeconfig | status) require_tools; ensure_init ;;
esac

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  down) cmd_down ;;
  destroy) shift; cmd_destroy "$@" ;;
  refresh) refresh_kubeconfig ;;
  kubeconfig) fetch_kubeconfig ;;
  status) cmd_status ;;
  -h | --help | help | "") usage ;;
  *) usage; exit 1 ;;
esac
