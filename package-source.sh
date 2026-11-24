#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 BUILD_NUMBER OUTPUT_DIRECTORY" >&2
    exit 64
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_number=$1
output_dir=$2
archive_path="$output_dir/Macdows-1.35-source.zip"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project_dir/Macdows.app/Contents/Info.plist")" = "$build_number"
mkdir -p "$output_dir"
scratch=$(mktemp -d "$output_dir/.macdows-source.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
stage_dir="$scratch/Macdows-1.35-source-build$build_number"
mkdir -p "$stage_dir/Macdows.app/Contents/Resources"
cp "$project_dir/Macdows.entitlements" "$stage_dir/"
cp "$project_dir/test.m" "$stage_dir/"
cp "$project_dir/RELEASE.md" "$stage_dir/"
cp "$project_dir/Macdows.app/Contents/Info.plist" "$stage_dir/Macdows.app/Contents/"
cp "$project_dir/Macdows.app/Contents/Resources/Macdows.m" "$stage_dir/Macdows.app/Contents/Resources/"
cp "$project_dir/Macdows.app/Contents/Resources/AppIcon.icns" "$stage_dir/Macdows.app/Contents/Resources/"
cp "$project_dir/Macdows.app/Contents/Resources/"*.applescript "$stage_dir/Macdows.app/Contents/Resources/"
if [ -f "$project_dir/SOURCE_README.md" ]; then
    cp "$project_dir/SOURCE_README.md" "$stage_dir/README.md"
else
    cp "$project_dir/README.md" "$stage_dir/README.md"
fi
cp "$project_dir/package-source.sh" "$project_dir/CHANGELOG.md" "$stage_dir/"

/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$stage_dir" "$scratch/source.zip"
mv -f "$scratch/source.zip" "$archive_path"
echo "$archive_path"
