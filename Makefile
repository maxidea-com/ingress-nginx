# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Add the following 'help' target to your Makefile
# And add help text after each target name starting with '\#\#'

.DEFAULT_GOAL:=help

.EXPORT_ALL_VARIABLES:

ifndef VERBOSE
.SILENT:
endif

# set default shell
SHELL=/bin/bash -o pipefail -o errexit

# Use the 0.0 tag for testing, it shouldn't clobber any release builds
TAG ?= 0.32.0

# Use docker to run makefile tasks
USE_DOCKER ?= true

# Disable run docker tasks if running in prow.
# only checks the existence of the variable, not the value.
ifdef DIND_TASKS
USE_DOCKER=false
endif

# e2e settings
# Allow limiting the scope of the e2e tests. By default run everything
FOCUS ?= .*
# number of parallel test
E2E_NODES ?= 15
# slow test only if takes > 50s
SLOW_E2E_THRESHOLD ?= 50
# run e2e test suite with tests that check for memory leaks? (default is false)
E2E_CHECK_LEAKS ?=

REPO_INFO ?= $(shell git config --get remote.origin.url)
GIT_COMMIT ?= git-$(shell git rev-parse --short HEAD)

PKG = k8s.io/ingress-nginx

HOST_ARCH = $(shell which go >/dev/null 2>&1 && go env GOARCH)
ARCH ?= $(HOST_ARCH)
ifeq ($(ARCH),)
    $(error mandatory variable ARCH is empty, either set it when calling the command or make sure 'go env GOARCH' works)
endif

REGISTRY ?= quay.io/kubernetes-ingress-controller

BASE_IMAGE ?= $(REGISTRY)/nginx:e3c49c52f4b74fe47ad65d6f3266a02e8b6b622f

GOARCH=$(ARCH)

# use vendor directory instead of go modules https://github.com/golang/go/wiki/Modules
GO111MODULE=off

help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: image
image: clean-image ## Build image for a particular arch.
	echo "Building docker image ($(ARCH))..."
	@cp -R bin/ rootfs/
	@docker build \
		--no-cache \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg VERSION="$(TAG)" \
		--build-arg TARGETARCH="$(ARCH)" \
		-t $(REGISTRY)/nginx-ingress-controller:$(TAG) rootfs

.PHONY: clean-image
clean-image: ## Removes local image
	echo "removing old image $(BASE_IMAGE):$(TAG)"
	@docker rmi -f $(BASE_IMAGE):$(TAG) || true

.PHONY: build
build: check-go-version ## Build ingress controller, debug tool and pre-stop hook.
ifeq ($(USE_DOCKER), true)
	@build/run-in-docker.sh \
		PKG=$(PKG) \
		ARCH=$(ARCH) \
		GIT_COMMIT=$(GIT_COMMIT) \
		REPO_INFO=$(REPO_INFO) \
		TAG=$(TAG) \
		GOBUILD_FLAGS=$(GOBUILD_FLAGS) \
		build/build.sh
else
	@build/build.sh
endif

.PHONY: build-plugin
build-plugin: check-go-version ## Build ingress-nginx krew plugin.
ifeq ($(USE_DOCKER), true)
	@build/run-in-docker.sh \
		PKG=$(PKG) \
		ARCH=$(ARCH) \
		GIT_COMMIT=$(GIT_COMMIT) \
		REPO_INFO=$(REPO_INFO) \
		TAG=$(TAG) \
		GOBUILD_FLAGS=$(GOBUILD_FLAGS) \
		build/build-plugin.sh
else
	@build/build-plugin.sh
endif

.PHONY: clean
clean: ## Remove .gocache directory.
	rm -rf bin/ .gocache/ .cache/

.PHONY: static-check
static-check: ## Run verification script for boilerplate, codegen, gofmt, golint, lualint and chart-lint.
ifeq ($(USE_DOCKER), true)
	@build/run-in-docker.sh \
		hack/verify-all.sh
else
	@hack/verify-all.sh
endif

.PHONY: test
test: check-go-version ## Run go unit tests.
ifeq ($(USE_DOCKER), true)
	@build/run-in-docker.sh \
		PKG=$(PKG) \
		ARCH=$(ARCH) \
		GIT_COMMIT=$(GIT_COMMIT) \
		REPO_INFO=$(REPO_INFO) \
		TAG=$(TAG) \
		GOBUILD_FLAGS=$(GOBUILD_FLAGS) \
		build/test.sh
else
	@build/test.sh
endif

.PHONY: lua-test
lua-test: ## Run lua unit tests.
ifeq ($(USE_DOCKER), true)
	@build/run-in-docker.sh \
		BUSTED_ARGS=$(BUSTED_ARGS) \
		build/test-lua.sh
else
	@build/test-lua.sh
endif

.PHONY: e2e-test
e2e-test: check-go-version ## Run e2e tests (expects access to a working Kubernetes cluster).
	@build/run-e2e-suite.sh

.PHONY: e2e-test-image
e2e-test-image: ## Build image for e2e tests.
	@make -C test/e2e-image

.PHONY: e2e-test-binary
e2e-test-binary: check-go-version ## Build ginkgo binary for e2e tests.
ifeq ($(USE_DOCKER), true)
	@build/run-in-docker.sh \
		ginkgo build ./test/e2e
else
	@ginkgo build ./test/e2e
endif

.PHONY: print-e2e-suite
print-e2e-suite: e2e-test-binary ## Prints information about the suite of e2e tests.
	@build/run-in-docker.sh \
		hack/print-e2e-suite.sh

.PHONY: cover
cover: check-go-version ## Run go coverage unit tests.
	@build/cover.sh
	echo "Uploading coverage results..."
	@curl -s https://codecov.io/bash | bash

.PHONY: vet
vet:
	@go vet $(shell go list ${PKG}/internal/... | grep -v vendor)

.PHONY: check_dead_links
check_dead_links: ## Check if the documentation contains dead links.
	@docker run -t \
	  -v $$PWD:/tmp aledbf/awesome_bot:0.1 \
	  --allow-dupe \
	  --allow-redirect $(shell find $$PWD -mindepth 1 -name "*.md" -printf '%P\n' | grep -v vendor | grep -v Changelog.md)

.PHONY: dep-ensure
dep-ensure: check-go-version ## Update and vendo go dependencies.
	GO111MODULE=on go mod tidy -v
	find vendor -name '*_test.go' -delete
	GO111MODULE=on go mod vendor

.PHONY: dev-env
dev-env: check-go-version ## Starts a local Kubernetes cluster using kind, building and deploying the ingress controller.
	@build/dev-env.sh

.PHONY: dev-env-stop
dev-env-stop: ## Deletes local Kubernetes cluster created by kind.
	@kind delete cluster --name ingress-nginx-dev

.PHONY: live-docs
live-docs: ## Build and launch a local copy of the documentation website in http://localhost:3000
	@docker run --rm -it -p 8000:8000 -v ${PWD}:/docs squidfunk/mkdocs-material:5.1.0

.PHONY: misspell
misspell: check-go-version ## Check for spelling errors.
	@go get github.com/client9/misspell/cmd/misspell
	misspell \
		-locale US \
		-error \
		cmd/* internal/* deploy/* docs/* design/* test/* README.md

.PHONY: kind-e2e-test
kind-e2e-test: check-go-version ## Run e2e tests using kind.
	@test/e2e/run.sh

.PHONY: kind-e2e-chart-tests
kind-e2e-chart-tests: ## Run helm chart e2e tests
	@test/e2e/run-chart-test.sh

.PHONY: run-ingress-controller
run-ingress-controller: ## Run the ingress controller locally using a kubectl proxy connection.
	@build/run-ingress-controller.sh

.PHONY: check-go-version
check-go-version:
ifeq ($(USE_DOCKER), true)
	@build/run-in-docker.sh \
		hack/check-go-version.sh
else
	@hack/check-go-version.sh
endif

.PHONY: init-docker-buildx
init-docker-buildx:
ifeq ($(DIND_TASKS),)
ifneq ($(shell docker buildx 2>&1 >/dev/null; echo $?),)
	$(error "buildx not available. Docker 19.03 or higher is required with experimental features enabled")
endif
	docker run --rm --privileged docker/binfmt:a7996909642ee92942dcd6cff44b9b95f08dad64
	docker buildx create --name ingress-nginx --use || true
	docker buildx inspect --bootstrap
endif

.PHONY: show-version
show-version:
	echo -n $(TAG)

PLATFORMS ?= amd64 arm arm64 s390x

EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
COMMA := ,

.PHONY: release # Build a multi-arch docker image
release: init-docker-buildx clean
	echo "Building binaries..."
	$(foreach PLATFORM,$(PLATFORMS), ARCH=$(PLATFORM) make build;)

	@cp -R bin/ rootfs/

	echo "Building and pushing ingress-nginx image..."
	@docker buildx build \
		--no-cache \
		--push \
		--progress plain \
		--platform $(subst $(SPACE),$(COMMA),$(PLATFORMS)) \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg VERSION="$(TAG)" \
		-t $(REGISTRY)/nginx-ingress-controller:$(TAG) rootfs
