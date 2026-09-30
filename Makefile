CHART := charts/cmangos
RELEASE ?= cmangos
NAMESPACE ?= cmangos
VALUES := -f build/images.generated.yaml $(if $(wildcard values.local.yaml),-f values.local.yaml)

.PHONY: lint template validate images install upgrade uninstall test

lint:
	helm lint $(CHART)

template:
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) $(VALUES) --dry-run=server

validate:
	@helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) $(VALUES) --dry-run=server >/dev/null \
		&& echo "server-side validation OK"

images:
	build/build-images.sh

install upgrade:
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace $(VALUES)

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE)

test:
	helm test $(RELEASE) -n $(NAMESPACE)
