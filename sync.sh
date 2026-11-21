#!/bin/sh
# Copy the addon files from this repository to the local AddOns folder.
# The target folder is the first line of .install-path.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
conf="$root/.install-path"

if [ ! -f "$conf" ]; then
    echo "Missing $conf. Copy .install-path.example to .install-path and set the addon folder." >&2
    exit 1
fi

dest=$(tr -d '\r' < "$conf" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed -n '1p')
if [ -z "$dest" ]; then
    echo "$conf is empty. Put the Interface/AddOns/EUI_GCDSpark path on its first line." >&2
    exit 1
fi

case "$dest" in
    "~/"*) dest="$HOME/${dest#\~/}" ;;
esac
dest=${dest%/}

case "$dest" in
    */EUI_GCDSpark) ;;
    *) echo "The install path must end in /EUI_GCDSpark: $dest" >&2; exit 1 ;;
esac

mkdir -p "$dest"
for file in EUI_GCDSpark.lua EUI_GCDSpark.toc; do
    cp "$root/$file" "$dest/$file"
done

echo "Synced EUI_GCDSpark to $dest"
