# MCS-1494: reproducing the stage tests

Tests the alert `WorkerNodeAutoReplacedNotification` from PR #2927: a ROSA HCP worker that the MachineHealthCheck (MHC)
replaces sends the customer one service log. The tests break worker nodes of a hosted cluster on purpose, so use a
disposable stage cluster.

## Prerequisites

### Access
- A stage OCM login, and backplane access to the **management cluster** that hosts the cluster under test, with
  elevation (`ocm backplane elevate`). Applying objects and running `exec` in the Prometheus pod need it.
- `cluster-admin` on the **hosted** cluster. The tests stop kubelet on workers with `oc debug node/...` and may need to
  force-delete pods stuck `Terminating`.
- Permission to read the cluster's service logs through the OCM API (`ocm get /api/service_logs/v1/...`).
- Optional, for recovering dead nodes without replacing them: AWS Session Manager or console access to the cluster's
  AWS account.

### Tools
`oc`, `ocm`, `rosa` (to scale machine pools), `jq`, and a shell on the management cluster (the ocm-container works).
`aws` only for the optional recovery above.

### The hosted cluster
- ROSA HCP 4.19 or newer, fully supported (not in limited support) and with alerts not silenced. Otherwise the
  suppression rule hides every alert and the tests show nothing.
- Every NodePool has auto-repair on (the default). Check that each pool has a MachineHealthCheck:
  `oc -n <hcp namespace> get machinehealthcheck`.
- Machine health limit: the MHC reports `spec.remediation.triggerIf.unhealthyLessThanOrEqualTo`. The default is **2**. The
  "too many unhealthy" test needs more unhealthy machines than that, so it needs a pool of at least **5** machines
  (3 killed, 2 left healthy). If a cluster overrides the limit with the annotation
  `hypershift.openshift.io/machine-health-check-max-unhealthy`, adjust the numbers.
- Pools for the single-node tests: at least two pools that can each lose one node, for example two single-machine pools.
- All machines `Ready` and every MHC showing `HEALTHY` equal to `EXPECTED` before each scenario.

### The management cluster
- The fleet `ocm-agent` is running (`ocm-agent-fleet` pods in `openshift-ocm-agent-operator`) and the stack's
  Alertmanager routes alerts labelled `send_managed_notification=true` to it. This is the existing setup.
- The namespace `hypershift-observability` exists with the label `hypershift.openshift.io/monitoring`, and the
  `kube-state-metrics` service account and cluster role are present. This is the existing setup.
- No other rule named `worker-node-auto-replaced*` is applied, or you get two alerts for one event.
- The cluster's last worker-node service log is **older than 24 hours**, or you lower `resendWait` on the
  `ManagedFleetNotification` for the test and restore it afterwards. Otherwise the first alert is deduplicated and you
  see no new service log.
- Machines of other hosted clusters on the same management cluster are not affected by the scoped test (it reads one
  namespace only), but the production rule would also match theirs.

### Objects you apply (all from this kit)
- `worker-node-auto-replaced.yaml`: the `ManagedFleetNotification` (the service log template).
- `scoped/10..50-*.yaml`: a second kube-state-metrics pod limited to the cluster under test, publishing the metric as
  `capitest_machine_info`. `scoped/20-deployment.yaml` carries the placeholder `REPLACE_HCP_NAMESPACE`, which the deploy
  step below replaces with the hosted control plane namespace of your cluster.
- `scoped/60-test-rule.PrometheusRule.yaml`: the PR's alert expression reading the scoped metric.
- `helpers.sh`: shell functions for the queries and monitors. Set `CID`, `EXT`, `CLUSTER_NAME` and `REASON` first.

### Time
Each failed-node scenario takes about 10 minutes after the kubelet stop (the MHC waits 8 minutes), plus recovery. The
five scenarios take about 2 to 3 hours in total.

### Safety
- The tests stop kubelet on real nodes and send a real service log to the test cluster. Use a throwaway cluster.
- This kit is not part of the PR; it lives on a separate testing branch. Remove all test objects from the clusters when
  done (cleanup commands in the steps below).
- Never put cluster passwords in this folder.

## Deploy all files

On the management cluster shell, from the folder that holds this kit:
```bash
export CID=<internal cluster id> EXT=<external cluster id (uuid)> CLUSTER_NAME=<hosted cluster name> REASON=<ticket>
source helpers.sh

# 1. the service log template
ocm backplane elevate "$REASON" -- apply -f worker-node-auto-replaced.yaml

# 2. the scoped kube-state-metrics, in this order. The deployment is limited to the namespace given by HCP_NAMESPACE
#    (set by helpers.sh), so substitute it into a temporary copy first.
sed "s|REPLACE_HCP_NAMESPACE|$HCP_NAMESPACE|" scoped/20-deployment.yaml > /tmp/20-deployment.yaml
for f in scoped/10-configmap.yaml scoped/50-networkpolicy.yaml /tmp/20-deployment.yaml scoped/30-service.yaml scoped/40-servicemonitor.yaml; do
  ocm backplane elevate "$REASON" -- apply -f $f
done
oc -n hypershift-observability rollout status deployment/kube-state-metrics-test

# 3. check the scoped metric before going on (wait about a minute)
qv 'up{job="kube-state-metrics-test"}'                        # value "1"
qv 'count by (exported_namespace) (capitest_machine_info)'    # only the hosted control plane namespace of the cluster

# 4. the test rule, then check both Prometheus stacks loaded it (wait 1-2 minutes)
ocm backplane elevate "$REASON" -- apply -f scoped/60-test-rule.PrometheusRule.yaml
for pod in prometheus-rhobs-hypershift-monitoring-stack-0 prometheus-hypershift-monitoring-stack-0; do
  ocm backplane elevate "$REASON" -- -n openshift-observability-operator exec $pod -c prometheus -- \
    curl -s localhost:9090/api/v1/rules | jq -c '.data.groups[].rules[] | select(.name=="WorkerNodeAutoReplacedNotificationTest") | {health,newExpr:(.query|contains("capitest_machine_info"))}'
done                                                           # health "ok", newExpr true on both
```
Before each scenario: `pool_state` shows every machine `Ready` and every MHC healthy, `wsl` gives the current number of
worker-node service logs (note it), and `q 'ALERTS{alertname="WorkerNodeAutoReplacedNotificationTest"}'` is empty.
Run `watch_alerts` and `watch_machines` (from `helpers.sh`) in two terminals during every scenario.

## Scenario 1: manual deletion, no service log
Draft; finalised after the run. The pool named `spot` on the test cluster uses standard on-demand instances, so this is
the same path as any pool.
```bash
ocm backplane elevate "$REASON" -- -n $HCP_NAMESPACE delete machines.cluster.x-k8s.io <machine of the spot pool>
```
Watch for 10 to 15 minutes. Expected: `HC` stays `True` for the whole deletion, `-- flagged:` stays empty, `-- alert:`
stays empty and `wsl` does not change.

## The service log window, and why the tests lower it
`ocm-agent` sends at most one service log per cluster and template inside the `resendWait` window, counted from the
last one it sent. In production that is **24 hours** (the value in `worker-node-auto-replaced.yaml`, as in the PR).

For Scenarios 2 and 3 the window is lowered to **1 hour** on the live object, so nobody waits a day. The file in this kit
stays at 24; the test patches the object and restores it afterwards.
- **Same mechanism, smaller scale.** The agent only compares the current time with the last send time plus
  `resendWait`. Using 1 hour exercises exactly the code path that 24 hours does. It lets you run both scenarios in one
  sitting, and it avoids waiting up to 24 hours when the cluster already received a worker-node service log recently
  (inside the window the first alert is deduplicated and Scenario 2 would show nothing).
- **Why 1 and not 0.** `resendWait` is in whole hours, and 0 is not "no window". The agent treats 0 as a special case
  and falls back to a 3-minute window. That is too short for Scenario 3: the second alert only fires about 10 minutes
  after the second node is stopped, so it would land outside a 3-minute window and send a service log. 1 hour is the
  smallest value that exercises the normal path, and it also keeps re-sent alerts from producing duplicate service logs.
- **What this means for Scenarios 3 and 4.** The second failure and the two-node failure have to be flagged within the
  hour after the service log of Scenario 2. After more than an hour the window has expired, and a new service log is the
  correct result.

Before Scenario 2:
```bash
oc -n openshift-ocm-agent-operator get managedfleetnotification worker-node-auto-replaced -o jsonpath='{.spec.fleetNotification.resendWait}{"\n"}'   # 24
ocm backplane elevate "$REASON" -- patch managedfleetnotification worker-node-auto-replaced -n openshift-ocm-agent-operator \
  --type merge -p '{"spec":{"fleetNotification":{"resendWait":1}}}'
wsl_last    # the window is open when this service log is more than 1 hour old, otherwise wait until it is
```
After Scenario 3, restore the PR's value:
```bash
ocm backplane elevate "$REASON" -- apply -f worker-node-auto-replaced.yaml
oc -n openshift-ocm-agent-operator get managedfleetnotification worker-node-auto-replaced -o jsonpath='{.spec.fleetNotification.resendWait}{"\n"}'   # 24
```

## Scenario 2: one failed node, service log sent
Draft; finalised after the run. With the window lowered and open (above), stop kubelet on one node of a single-machine
pool, on the hosted cluster:
```bash
oc debug node/<node> -- chroot /host systemctl stop kubelet
```
Expected, about 9 minutes later: `watch_machines` shows the machine with `HC=False`, `OWNER=False` and a deletion
timestamp; `watch_alerts` shows it flagged with `owner_remediated="False"`, then the alert, then `wsl` going up by one
(`wsl_last` shows the time). The MHC then replaces the machine.

## Scenario 3: second failure within the window, no service log
Draft; finalised after the run. Within the hour after the service log of Scenario 2, with `resendWait` still at 1,
repeat the kubelet stop on a node of a different single-machine pool.
Expected: the machine is flagged with `owner_remediated="False"` and the alert fires, but `wsl` stays at the value it had
after Scenario 2, because `ocm-agent` deduplicates inside the window. The production value of 24 hours behaves the same,
only for longer.

## Scenario 4: two nodes of the same pool fail, within the MHC limit
Draft; finalised after the run. Uses the pool of five machines. The MHC limit is 2 unhealthy machines
(`spec.remediation.triggerIf.unhealthyLessThanOrEqualTo`), so two failures are still remediated. Run it within the hour
after Scenario 2, while the window is open. On the hosted cluster, stop kubelet on two nodes of that pool at once:
```bash
for n in <node1> <node2>; do timeout 120 oc debug node/$n -- chroot /host systemctl stop kubelet & done; wait
```
Expected, about 9 minutes later: both machines show `HC=False`, `OWNER=False` and a deletion timestamp, both are listed
as flagged with `owner_remediated="False"`, the alert fires for both, and the MHC replaces both. `wsl` stays at its value
because the window is open; with a closed window there would be a single service log for the two machines, not two.
Check the MHC's own view while it happens:
```bash
oc -n $HCP_NAMESPACE get machinehealthcheck <pool> -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status}{"\n"}'   # RemediationAllowed=True
```

## Scenario 5: three nodes of the same pool fail, over the MHC limit, no alert
Draft; finalised after the run. This is the case the `owner_remediated` label exists for. With three unhealthy machines
in a pool of five, the MHC flags them but refuses to remediate any (`TooManyUnhealthy`), so nothing is being replaced
and the customer must not be told it is. Wait until the pool is back to five healthy machines, then stop kubelet on three
nodes at once:
```bash
for n in <node1> <node2> <node3>; do timeout 120 oc debug node/$n -- chroot /host systemctl stop kubelet & done; wait
```
Expected, about 9 minutes later, held for 5 more minutes: all three machines show `HC=False` with `OWNER` and `DEL`
empty; `-- flagged:` lists them **without** `owner_remediated`; `-- alert:` stays empty; `wsl` does not change. The MHC
status shows the reason:
```bash
oc -n $HCP_NAMESPACE get machinehealthcheck <pool> -o jsonpath='{.status.conditions[0].reason}{" - "}{.status.conditions[0].message}{"\n"}'
# TooManyUnhealthy - Remediation is not allowed, the number of not started or unhealthy machines exceeds maxUnhealthy (total: 5, unhealthy: 3, maxUnhealthy: 2)
```
Recovery: start kubelet again on the three nodes (Session Manager), or scale the pool down to 2 and back to 5. Drains of
dead nodes can stall on pods stuck `Terminating`; force-delete those pods.

## Cleanup
```bash
for f in 60-test-rule.PrometheusRule 40-servicemonitor 30-service 20-deployment 50-networkpolicy 10-configmap; do
  ocm backplane elevate "$REASON" -- delete -f scoped/$f.yaml --ignore-not-found
done
ocm backplane elevate "$REASON" -- delete managedfleetnotification worker-node-auto-replaced -n openshift-ocm-agent-operator --ignore-not-found
```
