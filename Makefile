SHELL := /bin/bash

.PHONY: all sync update build build-local test test-local package package-local clean

all: test build

sync:
	./scripts/sync-components.sh

update:
	COMPONENT="$(COMPONENT)" ./scripts/update-lock.sh

build: sync
	./scripts/build-all.sh

build-local:
	MACGRUBER_SOURCE_MODE=local ./scripts/build-all.sh

test: sync
	./scripts/test-all.sh

test-local:
	MACGRUBER_SOURCE_MODE=local ./scripts/test-all.sh

package: build
	VERSION="$(VERSION)" ./scripts/package-release.sh

package-local: build-local
	VERSION="$(VERSION)" ./scripts/package-release.sh

clean:
	rm -rf .build dist
