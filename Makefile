SHELL := /bin/bash

.PHONY: all sync update build build-amd64 build-local build-local-amd64 test test-local package package-amd64 package-local package-local-amd64 clean

all: test build

sync:
	./scripts/sync-components.sh

update:
	COMPONENT="$(COMPONENT)" ./scripts/update.sh

build: sync
	./scripts/build-all.sh

build-amd64: sync
	MACGRUBER_GOARCH=amd64 MACGRUBER_RUST_TARGET=x86_64-apple-darwin MACGRUBER_MACOSX_DEPLOYMENT_TARGET=10.15 MACGRUBER_BUILD_ROOT=.build/amd64 ./scripts/build-all.sh

build-local:
	MACGRUBER_SOURCE_MODE=local ./scripts/build-all.sh

build-local-amd64:
	MACGRUBER_SOURCE_MODE=local MACGRUBER_GOARCH=amd64 MACGRUBER_RUST_TARGET=x86_64-apple-darwin MACGRUBER_MACOSX_DEPLOYMENT_TARGET=10.15 MACGRUBER_BUILD_ROOT=.build/amd64 ./scripts/build-all.sh

test: sync
	./scripts/test-all.sh

test-local:
	MACGRUBER_SOURCE_MODE=local ./scripts/test-all.sh

package: build
	VERSION="$(VERSION)" ./scripts/package-release.sh

package-amd64: build-amd64
	MACGRUBER_GOARCH=amd64 MACGRUBER_RUST_TARGET=x86_64-apple-darwin MACGRUBER_MACOSX_DEPLOYMENT_TARGET=10.15 MACGRUBER_BUILD_ROOT=.build/amd64 VERSION="$(VERSION)" ./scripts/package-release.sh

package-local: build-local
	VERSION="$(VERSION)" ./scripts/package-release.sh

package-local-amd64: build-local-amd64
	MACGRUBER_SOURCE_MODE=local MACGRUBER_GOARCH=amd64 MACGRUBER_RUST_TARGET=x86_64-apple-darwin MACGRUBER_MACOSX_DEPLOYMENT_TARGET=10.15 MACGRUBER_BUILD_ROOT=.build/amd64 VERSION="$(VERSION)" ./scripts/package-release.sh

clean:
	rm -rf .build dist
