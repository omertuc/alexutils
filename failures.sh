#!/bin/bash

set -euxo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

export KUBECONFIG=/root/bm/kubeconfig

mkdir /root/omer/manifests -p

cd /root/omer

# Dump kubeconfigs
ls /root/omer/manifests/ | xargs -I % sh -c "echo %; oc get secret %-admin-kubeconfig -n % -o json | jq -r '.data.kubeconfig' | base64 -d > /root/omer/manifests/%/kubeconfig"

# List failures
oc get aci -A -ojson | jq '.items[] | select((.status.conditions[] | select(.type == "Failed")).status == "True") | .metadata.name' -r > faillist

# Crashes
for cluster in $(cat faillist); do
	export KUBECONFIG=manifests/$cluster/kubeconfig
    if ! oc get pods 2>/dev/null >/dev/null; then
        echo Offline $cluster
        continue
    fi
    if oc get pods -A | grep -E '(openshift-apiserver|openshift-authentication)' | grep -q Crash; then
        echo BadOVN $cluster
        continue
    fi
	if oc get pods -A | grep openshift-authentication | grep -q Crash; then
        echo BadOVN $cluster
        continue
    fi
	if oc get co machine-config  -ojson | jq '.status.conditions[] | select(.type=="Degraded").message' | grep -q "is being reported for"; then
        echo WeirdMCO $cluster
        continue
    fi
    if [[ $(oc get co -ojson | jq '[.items[] | select((.status.conditions[]? | select(.type == "Available").status) == "False").metadata.name] | length') == "1" ]]; then
        echo BadConsole $cluster
        continue
    fi
    echo Else $cluster
done
