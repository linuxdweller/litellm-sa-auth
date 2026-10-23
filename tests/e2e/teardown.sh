#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-litellm-e2e}"

kind delete cluster --name "$CLUSTER_NAME"
