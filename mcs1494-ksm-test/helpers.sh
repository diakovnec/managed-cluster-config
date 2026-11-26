#!/usr/bin/env bash
# Helpers for the MCS-1494 test run. Source it in a shell logged in to the management cluster:
#   export CID=<internal cluster id> EXT=<external cluster id (uuid)> CLUSTER_NAME=<cluster name> REASON=<ticket>
#   source helpers.sh

: "${CID:?set CID to the internal cluster id}"
: "${EXT:?set EXT to the external cluster id (uuid)}"
: "${CLUSTER_NAME:?set CLUSTER_NAME to the hosted cluster name}"
: "${REASON:?set REASON to the elevation reason}"

# Namespace of the hosted cluster object and of its control plane, on the management cluster.
# ENV is the part between "ocm-" and the id (staging on stage).
export ENV_PART="${ENV_PART:-staging}"
export HC_NAMESPACE="ocm-${ENV_PART}-${CID}"
export HCP_NAMESPACE="ocm-${ENV_PART}-${CID}-${CLUSTER_NAME}"
export PROM_POD="${PROM_POD:-prometheus-rhobs-hypershift-monitoring-stack-0}"
export POOL="${POOL:-spot}"

# Run an instant query against the management cluster Prometheus; prints each series' labels.
q() {
  ocm backplane elevate "$REASON" -- -n openshift-observability-operator exec "$PROM_POD" -c prometheus -- \
    curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" \
    | jq -c '.data.result[] | .metric | del(.container,.endpoint,.instance,.job,.pod,.service)'
}

# Same, but prints the value too.
qv() {
  ocm backplane elevate "$REASON" -- -n openshift-observability-operator exec "$PROM_POD" -c prometheus -- \
    curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" \
    | jq -c '.data.result[] | {metric: (.metric | del(.container,.endpoint,.instance,.job,.pod,.service)), value: .value[1]}'
}

# Number of "Worker node automatically replaced" service logs for the cluster.
wsl() {
  ocm get /api/service_logs/v1/clusters/cluster_logs --parameter cluster_id="$CID" --parameter cluster_uuid="$EXT" --parameter orderBy="timestamp desc" \
    | jq -c '[.items[] | select(.summary|test("Worker node"))] | length'
}

# Newest worker-node service log: time and summary.
wsl_last() {
  ocm get /api/service_logs/v1/clusters/cluster_logs --parameter cluster_id="$CID" --parameter cluster_uuid="$EXT" --parameter orderBy="timestamp desc" \
    | jq -c '[.items[] | select(.summary|test("Worker node"))][0] | {summary, service_name, created_at}'
}

# Monitor 1: the test alert, the flagged machines (with owner_remediated) and the service log count.
watch_alerts() {
  while true; do
    date -u +%T
    echo "-- alert:";   q 'ALERTS{alertname="WorkerNodeAutoReplacedNotificationTest"}' | jq -c '{alertname, machine_name}'
    echo "-- flagged:"; q 'capitest_machine_info{healthcheck_succeeded="False"}' | jq -c '{machine_name, healthcheck_succeeded, owner_remediated}'
    echo "-- worker-node SLs:"; wsl
    sleep "${INTERVAL:-20}"
  done
}

# Monitor 2: Machine conditions (HC = HealthCheckSucceeded, OWNER = OwnerRemediated, DEL = deletionTimestamp) and MHC health.
watch_machines() {
  while true; do
    date -u +%T
    oc -n "$HCP_NAMESPACE" get machines.v1beta1.cluster.x-k8s.io -o custom-columns='NAME:.metadata.name,HC:.status.conditions[?(@.type=="HealthCheckSucceeded")].status,OWNER:.status.conditions[?(@.type=="OwnerRemediated")].status,DEL:.metadata.deletionTimestamp' 2>&1 | grep -v Warning
    oc -n "$HCP_NAMESPACE" get machinehealthcheck -o custom-columns='MHC:.metadata.name,HEALTHY:.status.currentHealthy,EXPECTED:.status.expectedMachines'
    sleep "${INTERVAL:-20}"
  done
}

# Pool state at a glance.
pool_state() {
  oc -n "$HCP_NAMESPACE" get machinehealthcheck
  oc -n "$HCP_NAMESPACE" get machines.cluster.x-k8s.io
}
