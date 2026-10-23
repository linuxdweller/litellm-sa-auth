# LiteLLM On K8s With SA Auth

## Layout

```
charts/litellm/            Helm chart
tests/e2e/
  setup.sh                 kind cluster + Postgres + Secrets + helm install
  run.sh                   setup -> every tests/*.sh -> teardown
  teardown.sh              delete the kind cluster
  values-e2e.yaml          chart values for E2E (mock model, test SA allowlist)
  manifests/               Postgres, test ServiceAccounts
  tests/*.sh               one standalone script per test, non-zero exit = fail
```

## Running E2E

Requires `kind`, `kubectl`, `helm`, `docker`, `python3`.

```sh
make e2e            # full run, cluster deleted at the end
make e2e-setup      # or iterate: set up once...
make e2e-test       # ...re-run tests against the existing cluster
make e2e-teardown
```

The E2E model `e2e-mock` uses LiteLLM's `mock_response` with explicit
per-token pricing, so no provider API key is needed and budgets are hit in a
few requests. To add a test, drop a new script into `tests/e2e/tests/`.

`tests/e2e/tests/test-sa-budget.sh` can still be pointed at a real cluster via
env vars, e.g.
`KUBECONFIG=... MODEL=deepseek/deepseek-v4-pro tests/e2e/tests/test-sa-budget.sh`.
