#!/bin/zsh
# Runs the core checks (the Command Line Tools have no XCTest).
set -euo pipefail
cd "${0:A:h:h}"
swift build --product JouleChecks
.build/debug/JouleChecks
