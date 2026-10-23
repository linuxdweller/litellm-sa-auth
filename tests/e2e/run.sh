#!/usr/bin/env bash
# Runs the E2E suite: setup.sh, then every tests/*.sh in order, then
# teardown.sh. Each test is a standalone script that exits non-zero on
# failure and talks to the cluster via the current kubectl context.
#
#   SKIP_SETUP=1    reuse an already set-up cluster
#   KEEP_CLUSTER=1  don't delete the kind cluster afterwards
#   TESTS="a.sh b.sh"  run only these (names relative to tests/)
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-litellm-e2e}"
export CLUSTER_NAME

if [ "${KEEP_CLUSTER:-0}" != "1" ]; then
  trap '"${E2E_DIR}/teardown.sh"' EXIT
fi

if [ "${SKIP_SETUP:-0}" != "1" ]; then
  "${E2E_DIR}/setup.sh" || { echo "SETUP FAILED"; exit 1; }
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

if [ -n "${TESTS:-}" ]; then
  tests=()
  for t in $TESTS; do tests+=("${E2E_DIR}/tests/${t}"); done
else
  tests=("${E2E_DIR}"/tests/*.sh)
fi

passed=()
failed=()
for t in "${tests[@]}"; do
  name="$(basename "$t")"
  echo
  echo "################ ${name} ################"
  if bash "$t"; then
    passed+=("$name")
  else
    failed+=("$name")
  fi
done

echo
echo "================ E2E summary ================"
for n in "${passed[@]}"; do echo "PASS ${n}"; done
for n in "${failed[@]}"; do echo "FAIL ${n}"; done
[ "${#failed[@]}" -eq 0 ]
