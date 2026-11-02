#!/bin/bash
# Builds the swipe helper and installs both files into ~/.hammerspoon.
set -euo pipefail

source_dir="$(cd "$(dirname "$0")/src" && pwd)"
config_dir="$HOME/.hammerspoon"
stamp="$(date +%Y%m%d-%H%M%S)"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi

mkdir -p "$config_dir"

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
echo "Building the helper..."
swiftc -O "$source_dir/iphone-swipe.swift" -o "$build_dir/iphone-swipe"

for name in iphone-scroll.lua iphone-swipe iphone-swipe.swift; do
    if [ -e "$config_dir/$name" ]; then
        cp "$config_dir/$name" "$config_dir/$name.backup-$stamp"
        echo "Backed up $name to $name.backup-$stamp"
    fi
done

cp "$source_dir/iphone-scroll.lua" "$config_dir/iphone-scroll.lua"
cp "$source_dir/iphone-swipe.swift" "$config_dir/iphone-swipe.swift"
mv "$build_dir/iphone-swipe" "$config_dir/iphone-swipe"

load_line='dofile(hs.configdir .. "/iphone-scroll.lua")'
if ! grep -qF "$load_line" "$config_dir/init.lua" 2>/dev/null; then
    echo "$load_line" >> "$config_dir/init.lua"
    echo "Added the load line to init.lua"
fi

echo "Installed. In Hammerspoon choose Reload Config."
