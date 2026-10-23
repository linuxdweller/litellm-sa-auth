#!/usr/bin/env bash
# Verifies the per-SA auto-created-User budget enforced by the chart's
# custom_auth (charts/litellm/templates/configmap-callbacks.yaml):
#   1. a pod authenticating as the ${SA_NAME} ServiceAccount causes LiteLLM
#      to auto-create a User (system:serviceaccount:${NAMESPACE}:${SA_NAME})
#   2. that User's max_budget (from values saAuth.allowedServiceAccounts,
#      BUDGET below must match) is actually enforced -- repeated calls
#      eventually get a budget error (429 ExceededBudget; older LiteLLM: 400)
#   3. cleans up: deletes the LiteLLM User via the admin API, deletes the pod
#
# Requires: kubectl pointed (current context / KUBECONFIG) at a cluster with
# pod create/exec/delete and secret-read access to ${NAMESPACE}. Defaults
# match tests/e2e/values-e2e.yaml; override via env to run elsewhere.
set -euo pipefail

NAMESPACE="${NAMESPACE:-litellm}"
SA_NAME="${SA_NAME:-sa-jwt-test}"
SUB="system:serviceaccount:${NAMESPACE}:${SA_NAME}"
SVC_URL="${SVC_URL:-http://litellm.${NAMESPACE}.svc.cluster.local:4000}"
MODEL="${MODEL:-e2e-mock}"
BUDGET="${BUDGET:-0.01}"  # must match saAuth.allowedServiceAccounts[].maxBudget
MASTER_KEY_SECRET="${MASTER_KEY_SECRET:-litellm-master-key}"
MASTER_KEY_KEY="${MASTER_KEY_KEY:-masterKey}"
POD_NAME="sa-budget-test-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
# MAX_ATTEMPTS is computed after request 1 from its actual measured cost
# (budget / cost-per-call, +20% margin) -- the hammer loop then runs inside
# the pod in one kubectl exec to avoid per-call exec overhead at volume.

echo "== Fetching LiteLLM master key =="
MASTER_KEY=$(kubectl get secret "$MASTER_KEY_SECRET" -n "$NAMESPACE" -o jsonpath="{.data.${MASTER_KEY_KEY}}" | base64 -d)

cleanup() {
  echo "== Cleanup =="
  echo "-- deleting LiteLLM User ${SUB} (manual cleanup, admin API) --"
  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    curl -s -o /dev/null -w "user/delete status: %{http_code}\n" \
    -X POST "${SVC_URL}/user/delete" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"user_ids\": [\"${SUB}\"]}" || true
  echo "-- deleting pod ${POD_NAME} --"
  kubectl delete pod -n "$NAMESPACE" "$POD_NAME" --ignore-not-found --wait=false || true
}
trap cleanup EXIT

echo "== Creating test pod ${POD_NAME} (serviceAccountName=${SA_NAME}) =="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    purpose: sa-budget-test
spec:
  serviceAccountName: ${SA_NAME}
  # The default automounted SA token's aud claim is the apiserver's default
  # audiences, not "litellm" -- custom_auth.py's jwt.decode(audience=AUDIENCE)
  # rejects it. Request a token scoped to the litellm audience instead.
  automountServiceAccountToken: false
  restartPolicy: Never
  volumes:
    - name: litellm-token
      projected:
        sources:
          - serviceAccountToken:
              path: token
              audience: litellm
              expirationSeconds: 3600
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "3600"]
      volumeMounts:
        - name: litellm-token
          mountPath: /var/run/secrets/litellm
EOF

echo "== Waiting for pod to be ready =="
kubectl wait -n "$NAMESPACE" "pod/${POD_NAME}" --for=condition=Ready --timeout=60s

call_litellm() {
  # -i includes response headers in the output -- some providers don't
  # embed "cost" in the JSON body, only in the x-litellm-response-cost
  # header, so extract_cost checks both.
  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c '
    TOKEN=$(cat /var/run/secrets/litellm/token)
    curl -s -i -w "\n%{http_code}" -X POST "'"${SVC_URL}"'/chat/completions" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"'"${MODEL}"'\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}"
  '
}

extract_cost() {
  local c
  c=$(echo "$1" | grep -i '^x-litellm-response-cost:' | head -1 | awk '{print $2}' | tr -d '\r')
  if [ -z "$c" ]; then
    c=$(echo "$1" | grep -oE '"cost":[0-9.eE+-]+' | head -1 | cut -d: -f2)
  fi
  echo "$c"
}

user_info() {
  kubectl exec -n "$NAMESPACE" "$POD_NAME" -- \
    curl -s -X GET "${SVC_URL}/user/info" \
    -G --data-urlencode "user_id=${SUB}" \
    -H "Authorization: Bearer ${MASTER_KEY}"
}

echo "== Request 1: first call from ${SUB} =="
resp=$(call_litellm)
status="${resp##*$'\n'}"
body="${resp%$'\n'*}"
first_cost=$(extract_cost "$body")
echo "status=${status} cost=${first_cost}"

if [ "$status" != "200" ]; then
  echo "FAIL: first call did not succeed (status=${status})"
  echo "body=${body}"
  exit 1
fi

MAX_ATTEMPTS=$(python3 -c "
import math
cost = float('${first_cost:-0}' or 0)
budget = ${BUDGET}
if cost <= 0:
    print(50)
else:
    print(min(2000, max(10, math.ceil(budget / cost * 1.2))))
")
echo "measured cost/call=${first_cost} -> MAX_ATTEMPTS=${MAX_ATTEMPTS}"

echo "== Checking a LiteLLM User was auto-created =="
info=$(user_info)
if echo "$info" | grep -q "\"user_id\":\"${SUB}\"\|\"user_id\": \"${SUB}\""; then
  echo "PASS: User ${SUB} exists in LiteLLM"
else
  echo "FAIL: User ${SUB} not found after first request"
  echo "$info"
  exit 1
fi
echo "$info" | python3 -c "import json,sys; d=json.load(sys.stdin); u=d.get('user_info',d); print('max_budget:', u.get('max_budget')); print('spend:', u.get('spend'))" || echo "$info"

echo "== Hammering the key until budget enforcement kicks in (max ${MAX_ATTEMPTS} attempts, run in-pod) =="
hammer_out=$(kubectl exec -n "$NAMESPACE" "$POD_NAME" -- sh -c '
  TOKEN=$(cat /var/run/secrets/litellm/token)
  i=2
  while [ "$i" -le '"${MAX_ATTEMPTS}"' ]; do
    resp=$(curl -s -i -w "\n%{http_code}" -X POST "'"${SVC_URL}"'/chat/completions" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"'"${MODEL}"'\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed "\$d")
    if [ "$i" = 2 ] || [ $(( i % 100 )) = 0 ]; then
      echo "attempt $i status=$code"
    fi
    case "$code" in
      400|429)
        case "$body" in
          *[Bb]udget*)
            echo "BUDGET_HIT at attempt $i"
            echo "$body"
            exit 0
            ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  echo "NOT_HIT"
')
echo "$hammer_out"

if echo "$hammer_out" | grep -q "^BUDGET_HIT"; then
  echo "PASS: budget exceeded"
  budget_hit=true
else
  budget_hit=false
fi

if [ "$budget_hit" != "true" ]; then
  echo "FAIL: never hit budget enforcement within ${MAX_ATTEMPTS} attempts"
  user_info
  exit 1
fi

echo "== Final user state =="
user_info
echo
echo "All checks passed."
