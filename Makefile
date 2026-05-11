.PHONY: build test test-signatures test-storage

build:
	forge build

test:
	forge test -vvv

test-signatures:
	./test/signatures/test-sigs.bash

test-storage:
	./test/storage/test-storage.bash
