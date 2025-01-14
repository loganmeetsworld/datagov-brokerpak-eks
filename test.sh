#!/bin/bash

# Test that a provisioned instance is set up properly and meets requirements 
#   ./test.sh BINDINGINFO.json
# 
# Returns 0 (if all tests PASS)
#      or 1 (if any test FAILs).

set -e
retval=0

if [[ -z ${1+x} ]] ; then
    echo "Usage: ./test.sh BINDINGINFO.json"
    exit 1
fi

SERVICE_INFO="$(jq -r .credentials < "$1")"

# Set up the kubeconfig
KUBECONFIG=$(mktemp)
export KUBECONFIG
echo "$SERVICE_INFO" | jq -r '.kubeconfig' > "${KUBECONFIG}"
DOMAIN_NAME=$(echo "$SERVICE_INFO" | jq -r '.domain_name')
export DOMAIN_NAME

echo "To work directly with the instance:"
echo "export KUBECONFIG=${KUBECONFIG}"
echo "export DOMAIN_NAME=${DOMAIN_NAME}"
echo "Running tests..."

# Test 1
echo "Deploying the test fixture..."
export SUBDOMAIN=subdomain-2048
export TEST_HOST=${SUBDOMAIN}.${DOMAIN_NAME}
export TEST_URL=https://${TEST_HOST}

cat <<-TESTFIXTURE | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deployment-2048
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: app-2048
  replicas: 2
  template:
    metadata:
      labels:
        app.kubernetes.io/name: app-2048
    spec:
      containers:
      - image: alexwhen/docker-2048
        imagePullPolicy: Always
        name: app-2048
        ports:
        - containerPort: 80
        securityContext:
          allowPrivilegeEscalation: false
---
apiVersion: v1
kind: Service
metadata:
  name: service-2048
spec:
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: ClusterIP
  selector:
    app.kubernetes.io/name: app-2048
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${SUBDOMAIN}
  annotations:
   nginx.ingress.kubernetes.io/rewrite-target: /
   # We want TTL to be quick in case we want to run tests in quick succession
   external-dns.alpha.kubernetes.io/ttl: "30"
spec:
  rules:
  - host: ${TEST_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: service-2048
            port:
              number: 80
TESTFIXTURE

# We set the ingress to appear at a subdomain. It will take a minute for
# external-dns to make the Route 53 entry for that subdomain, and for that
# record to propagate. By waiting here, we are testing that both the
# ingress-nginx controller and external-dns are working correctly.
# 
# Notes: 
#   - host and dig are not available in the CSB container, but nslookup is.
#   - We have found that the propagation speed for both the CNAME and DS record
#     can be v-e-r-y s-l-o-w and depend a lot on your DNS provider. Which is why
#     we've set the timeout to 30 minutes here.
echo -n "Waiting up to 1800 seconds for the ${TEST_HOST} subdomain to be resolvable..."
time=0
while true; do
  # I'm not crazy about this test but I can't think of a better one.

  if (nslookup -type=CNAME "$TEST_HOST" | grep -q "canonical name ="); then
    echo PASS
    break
  elif [[ $time -gt 1800 ]]; then
    retval=1; echo FAIL; break;
  fi
  time=$((time+5))
  sleep 5
  echo -ne "\r($time seconds) ..."

done

echo "You can try the fixture yourself by visiting:"
echo "${TEST_URL}"

echo -n "Waiting up to 600 seconds for the ingress to respond with the expected content via SSL..."
time=0
while true; do
  if (curl --silent --show-error "${TEST_URL}" | grep -F '<title>2048</title>'); then
    echo PASS; break;
  elif [[ $time -gt 600 ]]; then
    retval=1; echo FAIL; break;
  fi
  time=$((time+5))
  sleep 5
  echo -ne "\r($time seconds) ..."
done

# timeout(): Test whether a command finishes before a deadline 
# Usage:
#   timeout <cmd...> 
# Optionally, set TIMEOUT_DEADLINE_SECS to something other than the default 65s.
# You may want to wrap more complex commands in a function and pass that.
#
# This idea for testing whether a command times out comes from:
# http://blog.mediatribe.net/fr/node/72/index.html
function timeout () {
    local timeout=${TIMEOUT_DEADLINE_SECS:-65}
    "$@" 2>/dev/null & 
    sleep "${timeout}"
    # If the process has already exited, kill returns a non-zero exit status If
    # the process hasn't already exited, kill returns a zero exit status
    if kill $! > /dev/null 2>&1 
    then
        # The command was still running at the deadline and had to be killed
        echo "The command did NOT exit within ${timeout} seconds."
        return 1
    else
        # ...the command had already exited by the deadline without being killed
        echo "The command exited within ${timeout} seconds."
    fi
}

# Hold an SSL connection open until the connection is closed from the other end,
# or the process is killed. timeout() will complain if it takes longer than 65
# seconds to end on its own.
echo -n "Testing that connections are closed after 60s of inactivity... "
if (timeout openssl s_client -quiet -connect "${TEST_HOST}":443); then 
  echo PASS; 
else 
  retval=1; 
  echo FAIL; 
fi

# We are explicitly disabling the followiung DNSSEC configuration validity test
# until we can do it without relying on unknown intermediate resolver support
# for DNSSEC. See issue here: 
#   https://github.com/gsa/data.gov/issues/3751

# echo -n "Waiting up to 600 seconds for the DNSSEC chain-of-trust to be validated... "
# time=0
# while true; do
#   if [[ $(delv "${DOMAIN_NAME}" +yaml | grep -o '\s*\- fully_validated:' | wc -l) != 0 ]]; then
#     echo PASS; 
#     break; 
#   elif [[ $time -gt 600 ]]; then 
#     retval=1; 
#     echo FAIL; 
#     break; 
#   fi
#   time=$((time+5))
#   sleep 5
#   echo -ne "\r($time seconds) ..."
# done

# Test 2 - ebs dynamic provisioning
echo -n "Provisioning PV resources... "
kubectl apply -f test_specs/pv/ebs/claim.yml
kubectl apply -f test_specs/pv/ebs/pod.yml

echo -n "Waiting for Pod to start..."
kubectl wait --for=condition=ready --timeout=600s pod ebs-app
sleep 10

echo -n "Verify pod can write to EFS volume..."
if (kubectl exec -ti ebs-app -- cat /data/out.txt | grep -q "Pod was here!"); then
    echo PASS
else 
    retval=1
    echo FAIL
fi

# Test 3 - no egress traffic
if (kubectl exec -it ebs-app -- sh -c "ping -c 4 8.8.8.8" | grep -q "100% packet loss"); then
    echo pass
else
    retval=1
    echo FAIL
fi

#######
## From here down, tests need a KUBECONFIG with an admin user to complete correctly, so let's make a new one
# Grab the name of the cluster for use with the aws CLI
CLUSTER_NAME=$(kubectl config view -o jsonpath='{.contexts[].context.cluster}')
rm "${KUBECONFIG}"

KUBECONFIG=$(mktemp)
export KUBECONFIG

# Since we expect AWS creds are already set in the environment to a user for the broker to use, we
# can use this command to generate the admin kubeconfig
aws eks update-kubeconfig --kubeconfig "$KUBECONFIG" --name "$CLUSTER_NAME" 

# Test that the CIS EKS benchmark for the last node shows a total of zero FAIL results
if (kubectl get CISKubeBenchReport "$(kubectl get nodes | tail -1 | cut -d ' ' -f 1)" -o json | jq -r '[.report.sections[].tests[].fail | tonumber] | add' | grep -q 0); then
    echo pass
else
    retval=1
    echo FAIL
fi

# Cleanup
rm "${KUBECONFIG}"
echo "You can reset your terminal without losing backscroll by running: stty sane"
exit $retval

