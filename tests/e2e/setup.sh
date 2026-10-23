#!/usr/bin/env bash
# Spins up a kind cluster with a throwaway Postgres, the Secrets the chart
# expects (it never creates them itself), and the litellm chart installed
# with values-e2e.yaml. Idempotent: re-running reuses the cluster and Secrets
# and just upgrades the release.
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${E2E_DIR}/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-litellm-e2e}"
NAMESPACE="${NAMESPACE:-litellm}"
RELEASE="${RELEASE:-litellm}"

random_alnum() {
  # Alphanumeric only: the DB password is interpolated into DATABASE_URL.
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
}

echo "== kind cluster ${CLUSTER_NAME} =="
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --name "$CLUSTER_NAME" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "== Secrets =="
if ! kubectl get secret litellm-db -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create secret generic litellm-db -n "$NAMESPACE" \
    --from-literal=username=litellm \
    --from-literal=password="$(random_alnum 32)"
fi
if ! kubectl get secret litellm-master-key -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create secret generic litellm-master-key -n "$NAMESPACE" \
    --from-literal=masterKey="sk-$(random_alnum 40)"
fi

echo "== Postgres =="
kubectl apply -n "$NAMESPACE" -f "${E2E_DIR}/manifests/postgres.yaml"
kubectl rollout status -n "$NAMESPACE" deployment/postgres --timeout=180s

echo "== Test ServiceAccounts =="
kubectl apply -n "$NAMESPACE" -f "${E2E_DIR}/manifests/test-serviceaccounts.yaml"

echo "== Installing chart (release ${RELEASE}) =="
helm upgrade --install "$RELEASE" "${REPO_ROOT}/charts/litellm" \
  -n "$NAMESPACE" \
  -f "${E2E_DIR}/values-e2e.yaml" \
  --wait --timeout 15m

echo "== Setup complete =="
