#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
configuration="${1:-release}"
destination="${2:-${repo_root}/dist/OmaQuote.app}"

if ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$repo_root"
swift build --disable-sandbox -c "$configuration"
bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
cp App/Info.plist "$destination/Contents/Info.plist"
cp "$bin_path/OmaQuoteMac" "$destination/Contents/MacOS/OmaQuoteMac"
cp "$bin_path/omaquote" "$destination/Contents/MacOS/omaquote"
ditto "$bin_path/OmaQuoteMac_OmaQuoteCore.bundle" "$destination/Contents/Resources/OmaQuoteMac_OmaQuoteCore.bundle"
codesign --force --deep --sign - "$destination"
echo "$destination"
