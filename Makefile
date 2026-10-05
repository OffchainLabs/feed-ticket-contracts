.PHONY: build test test-signatures test-storage test-upgrade

build:
	forge build

test:
	forge test -vvv

test-signatures:
	./test/signatures/test-sigs.bash

test-storage:
	./test/storage/test-storage.bash

test-upgrade:
	./test/upgrade/test-upgrade.bash
