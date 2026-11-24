#!/usr/bin/env bash
# Rebuilds the ROM file the build reads, for CI, from the ROM_BANK0 secret.
#
# The ROM can't be committed, and the whole ROM is too big for a GitHub secret
# (48 KB). But tools/romextract reads only the iNES header and bank 0, so the
# secret holds just those 16400 bytes, gzipped and base64-encoded. The rest of
# the file is zeros, which is fine for every build step but NOT for
# `zig build romcheck`: never run romcheck on this file.
#
# Writes $RUNNER_TEMP/dragon_warrior.nes and exports ROM=<that path> to the
# job's later steps. See .github/workflows/README.md for setting the secret.
set -euo pipefail

# sha256 of the first 16400 bytes of Dragon Warrior (U).
bank0_sha256=a3f31a7b3c476e0ad72bcdc42a3bdc722d1e07f5a4f54594cfe91a4b7a2d070a
bank0_size=16400
rom_size=81936
out=${RUNNER_TEMP:?}/dragon_warrior.nes

if [ -z "${ROM_BANK0:-}" ]; then
  echo "::error::The ROM_BANK0 secret is not set (pull requests from forks never get it). See .github/workflows/README.md#set-up-the-repository-once"
  exit 1
fi

printf '%s' "$ROM_BANK0" | base64 -d | gzip -dc >"$out"

# shasum is on both the Linux and the macOS runners; sha256sum isn't on macOS.
if [ "$(shasum -a 256 <"$out" | cut -d' ' -f1)" != "$bank0_sha256" ]; then
  echo "::error::ROM_BANK0 doesn't decode to Dragon Warrior (U)'s header and bank 0. See .github/workflows/README.md#set-up-the-repository-once"
  exit 1
fi

head -c $((rom_size - bank0_size)) /dev/zero >>"$out"
echo "ROM=$out" >>"$GITHUB_ENV"
