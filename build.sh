#!/bin/sh
# build.sh — regenerate the SpoonInstall files after changing the Spoon. Run it before committing.
#
# Needs Hammerspoon running with its `hs` command-line tool (require("hs.ipc") in your init.lua).
#
# Outputs (both committed, SpoonInstall downloads them from GitHub):
#   docs/docs.json                    metadata SpoonInstall reads, generated from the `---` docstrings in init.lua
#   Spoons/WindowSwitcher.spoon.zip   the download: one WindowSwitcher.spoon folder with the source files
#
# Example: releasing a new version → bump obj.version in init.lua, run ./build.sh, commit, push
# Example: ship another file in the zip → add it to FILES below

set -e
cd "$(dirname "$0")"
FILES="init.lua glass.swift LICENSE README.md README.zh-CN.md"

# 1. docs.json. sed drops any "-- Loading extension" log lines printed before the JSON.
mkdir -p docs
hs -c "print(hs.doc.builder.genJSON('$PWD'))" | sed -n '/^\[/,$p' > docs/docs.json

# 2. zip. Files are copied into a temp WindowSwitcher.spoon folder first, so the zip holds exactly
#    one .spoon folder no matter what this repo's folder is called. The compiled glass is left out:
#    it's built on each user's machine. -X drops extra file attributes (owner IDs etc.)
STAGE=$(mktemp -d)
mkdir "$STAGE/WindowSwitcher.spoon"
cp $FILES docs/docs.json "$STAGE/WindowSwitcher.spoon/"
mkdir -p Spoons
rm -f Spoons/WindowSwitcher.spoon.zip
(cd "$STAGE" && zip -q -r -X "$OLDPWD/Spoons/WindowSwitcher.spoon.zip" WindowSwitcher.spoon)
rm -r "$STAGE"

echo "Built docs/docs.json and Spoons/WindowSwitcher.spoon.zip"
