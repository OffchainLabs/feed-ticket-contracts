#!/bin/bash

# Builds Tickets at the 1.0.1 tag, then runs the upgrade fuzz test against that bytecode.
# usage: ./test/upgrade/test-upgrade.bash [forge test args]

set -euo pipefail

# tracked changes would block the checkout or leak into the 1.0.1 build
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    echo "Commit or stash tracked changes first"
    exit 1
fi

git -c advice.detachedHead=false checkout -q 1.0.1
trap 'git checkout -q -' EXIT
forge build src
TICKETS_V1_0_1_BYTECODE=$(jq -re .bytecode.object out/Tickets.sol/Tickets.json)
export TICKETS_V1_0_1_BYTECODE
git checkout -q -
trap - EXIT

forge test --match-path test/TicketsUpgrade.t.sol "$@"
