IMG ?= localhost:5001/ai-inference-operator:dev
KUSTOMIZE ?= kubectl kustomize

.PHONY: fmt vet test build docker-build docker-push manifests install uninstall deploy kind-up

fmt:
	go fmt ./...

vet:
	go vet ./...

test: fmt vet
	go test ./...

build:
	go build -o bin/manager ./cmd/manager

docker-build:
	docker build -t $(IMG) .

docker-push:
	docker push $(IMG)

manifests:
	mkdir -p dist
	$(KUSTOMIZE) config/default > dist/install.yaml

install:
	kubectl apply -k config/crd

uninstall:
	kubectl delete -k config/default --ignore-not-found

deploy:
	cd config/manager && kustomize edit set image controller=$(IMG)
	kubectl apply -k config/default

kind-up:
	hack/kind-up.sh
