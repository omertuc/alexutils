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
    if oc get co -ojson 2>/dev/null | jq '
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
    elif oc get pods -A -ojson | jq ' .items[] | select(.status.containerStatuses[]?.state.waiting?.reason == "ContainerCreating").metadata | {name, namespace}' -c | while read -r x; do oc get events -n "$(echo "$x" | jq '.namespace' -r)" -ojson | jq --arg name "$(echo "$x" | jq '.name' -r)" ' .items[] | select(.involvedObject.name == $name).reason'; done | jq --exit-status --slurp '[.[] | select(. == "FailedMount")] | length > 10' >/dev/null; then
         echo VolumeMountIssue "$cluster"
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
