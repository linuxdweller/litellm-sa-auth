CHART := charts/litellm

.PHONY: lint e2e e2e-setup e2e-test e2e-teardown

lint:
	helm lint $(CHART) -f tests/e2e/values-e2e.yaml

# Full run: create kind cluster, install, run all tests, delete cluster.
e2e:
	tests/e2e/run.sh

# Iterative loop: `make e2e-setup` once, then `make e2e-test` repeatedly.
e2e-setup:
	tests/e2e/setup.sh

e2e-test:
	SKIP_SETUP=1 KEEP_CLUSTER=1 tests/e2e/run.sh

e2e-teardown:
	tests/e2e/teardown.sh
