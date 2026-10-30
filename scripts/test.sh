#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/localeshift-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/localeshift-modules"
localeshift_flags=()
localeshift_frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ -d "$localeshift_frameworks/Testing.framework" ]]; then
  localeshift_flags=(-Xswiftc -F -Xswiftc "$localeshift_frameworks" -Xlinker -rpath -Xlinker "$localeshift_frameworks" -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib)
fi
swift test --disable-sandbox "${localeshift_flags[@]}" "$@"
