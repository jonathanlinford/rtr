#!/bin/bash
# Run unit tests.
#
# On a machine with Xcode installed, plain `swift test` works.
# On a machine with only Command Line Tools, swift-testing's framework
# isn't on the default search/rpath — wire it up explicitly here.

set -euo pipefail
cd "$(dirname "$0")"

CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [ -d "$CLT_FW/Testing.framework" ] && ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$CLT_FW" \
        -Xlinker -rpath -Xlinker "$CLT_FW" \
        -Xlinker -rpath -Xlinker "$CLT_LIB" \
        "$@"
fi

exec swift test "$@"
