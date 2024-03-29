#!/bin/bash

set -euxo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

export KUBECONFIG=/root/bm/kubeconfig

mkdir /root/omer/manifests -p

cd /root/omer

for n in $(seq -f "%05g" 1 3700); do
	mkdir /root/omer/manifests/vm${n} -p
done

# List failures
export KUBECONFIG=/root/bm/kubeconfig
oc get aci -A -ojson | jq '.items[] | select((.status.conditions[] | select(.type == "Failed")).status == "True") | .metadata.name' -r >faillist

# Dump kubeconfigs
export KUBECONFIG=/root/bm/kubeconfig
cat faillist | xargs -I % sh -c "echo %; oc get secret %-admin-kubeconfig -n % -o json | jq -r '.data.kubeconfig' | base64 -d > /root/omer/manifests/%/kubeconfig"

export KUBECONFIG=/root/bm/kubeconfig
for cluster in $(cat faillist); do
    export KUBECONFIG=manifests/$cluster/kubeconfig
    if oc get clusterversion -ojson 2>/dev/null | jq --exit-status '.items[].status.conditions[] | select(.type == "Available").status == "True"' > /dev/null; then
         echo Healthy "$cluster"
    elif oc get co -ojson 2>/dev/null | jq --exit-status '
            [
                .items[] 
                | select(
                    .status.conditions[] 
                    | select(.type == "Available").status == "False"
                )
            ] as $x 
            | (($x | length) == 1 and $x[0].metadata.name == "etcd")
        '>/dev/null 2>/dev/null; then
         echo EtcdLeaseStuck "$cluster"
    elif oc get co -ojson 2>/dev/null | jq --exit-status '
            [
                .items[] 
                | select(
                    .status.conditions[] 
                    | select(.type == "Degraded").status == "True"
                )
            ] as $x 
            | (($x | length) == 1 and $x[0].metadata.name == "machine-config")
        '>/dev/null 2>/dev/null; then
         echo MachineConfigIssue "$cluster"
    elif oc get pods -A -ojson | jq ' .items[] | select(.status.containerStatuses[]?.state.waiting?.reason == "ContainerCreating").metadata | {name, namespace}' -c | while read -r x; do oc get events -n "$(echo "$x" | jq '.namespace' -r)" -ojson | jq --arg name "$(echo "$x" | jq '.name' -r)" ' .items[] | select(.involvedObject.name == $name).reason'; done | jq --exit-status --slurp '[.[] | select(. == "FailedMount")] | length > 10' >/dev/null; then
         echo VolumeMountIssue "$cluster"
    elif oc get pods -n openshift-kube-controller-manager kube-controller-manager-"$cluster" 2>/dev/null | grep Completed -q; then
        echo NoKubeControllerManagedStaticPod "$cluster"
    elif oc get pods -n openshift-kube-scheduler openshift-kube-scheduler-"$cluster" 2>/dev/null | grep Completed -q; then
        echo NoSchedulerStaticPod "$cluster"
    elif oc get co etcd -ojson | jq --exit-status ' .status.conditions[] | select(.type == "Degraded").reason == "MissingStaticPodController_SyncError"' > /dev/null; then
        echo NoEtcdStaticPod "$cluster"
    elif oc get pods -n openshift-kube-controller-manager kube-controller-manager-"$cluster" -ojson 2>/dev/null | jq '.status.containerStatuses[] | select(.name == "kube-controller-manager").ready | not' --exit-status >/dev/null; then
        echo UnreadyKubeControllerManager "$cluster"
    elif oc get pods -n openshift-etcd etcd-"$cluster" -ojson 2>/dev/null | jq '.status.containerStatuses[] | select(.name == "etcd").ready | not' --exit-status >/dev/null; then
        echo UnreadyEtcd "$cluster"
    elif oc logs -n openshift-machine-api deployment/cluster-baremetal-operator -c cluster-baremetal-operator 2>/dev/null | grep "unable to start manager" -q; then
        echo ClusterBaremetalOperatorManagerStartFailed "$cluster"
    elif [[ $(oc get pods -n openshift-kube-controller-manager kube-controller-manager-"$cluster" -ojson 2>/dev/null | jq '.metadata.labels.revision' -r) != $(oc get pods -n openshift-kube-controller-manager -ojson | jq '[.items[] | select(.metadata.name | test("^installer-.*")).metadata.name] | sort[-1]' -r | cut -d"-" -f2) ]]; then
        echo BadKubeControllerManagerRevision "$cluster"
    elif [[ $(oc get pods -n openshift-kube-scheduler openshift-kube-scheduler-"$cluster" -ojson 2>/dev/null | jq '.metadata.labels.revision' -r) != $(oc get pods -n openshift-kube-scheduler -ojson | jq '[.items[] | select(.metadata.name | test("^installer-.*")).metadata.name] | sort[-1]' -r | cut -d"-" -f2) ]]; then
        echo BadSchedulerRevision "$cluster"
    else
        echo Other "$cluster"
    fi
done

# Event scanning example
cd /root/omer
export KUBECONFIG=/root/bm/kubeconfig
cat faillist | while read -r x; do
	echo $x
	curl -s -k $(oc get aci -n $x $x -ojson | jq '.status.debugInfo.eventsURL' -r) | jq -r '
        .[] 
        | select(
            (.message | test("connected"))
            and
            (.message | test("is now failing"))
        ).event_time'
done
