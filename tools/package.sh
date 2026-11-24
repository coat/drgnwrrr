#!/usr/bin/env bash
# Packages a desktop build from ./out into ./dist for a release: the native
# game, the CLI game, the README and the licenses.
#
# Usage: tools/package.sh <platform>, such as x86_64-linux or x86_64-windows.
# Names the package after $VERSION, or the short commit SHA when it is empty.
set -euo pipefail

platform=$1
commit=${COMMIT:-$(git rev-parse HEAD)}
version=${VERSION:-${commit:0:7}}
dir=drgnwrrr-$version-$platform

case $platform in
*-windows) ext=.exe ;;
*) ext= ;;
esac

mkdir -p dist "$dir"
cp "out/bin/drgnwrrr$ext" "out/bin/drgnwrrr-cli$ext" README.md "$dir"
cp -R out/licenses "$dir"

# Windows users expect a zip; tar keeps the executable bit for everyone else.
case $platform in
*-windows) zip -r "dist/$dir.zip" "$dir" ;;
# COPYFILE_DISABLE stops macOS tar adding ._* files for extended attributes.
*) COPYFILE_DISABLE=1 tar czf "dist/$dir.tar.gz" "$dir" ;;
esac
