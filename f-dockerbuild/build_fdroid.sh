#!/bin/bash
set -e

# Number of CPUs the build container is pinned to. This is NOT a performance knob:
# R8 produces a different classes.dex depending on how many processors it sees, so
# this has to match whatever the verifier uses or the reproducible build fails.
# Check the latest CPUS_MAX configuration on F-Droid:
# https://gitlab.com/fdroid/fdroiddata/-/blob/master/metadata/app.murinelauncher.yml
CPUS=4

# Everything runs inside this block so bash parses the whole script up front. Otherwise
# it reads the file incrementally, and saving an edit mid-build makes it resume at a
# stale byte offset and die on whatever text now sits there.
{

OUTPUT_DIR="$1"
COMMIT_OVERRIDE="$2"  # Optional commit SHA

if [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <output-directory-wsl-path> [COMMIT_HASH/COMMIT_TAG]"
    exit 1
fi

REPO_URL="https://github.com/alesimula/Murine-launcher"
RAW_URL="https://raw.githubusercontent.com/alesimula/Murine-launcher"

# --- Step 1: Determine which commit to use ---
# Without an override, resolve the newest commit.
# Done here rather than via `fdroid checkupdates`, which appends Builds entries.
if [ -n "$COMMIT_OVERRIDE" ]; then
    COMMIT="$COMMIT_OVERRIDE"
    echo "==> Using provided commit: $COMMIT"
else
    echo "==> Fetching latest commit from GitHub..."
    COMMIT=$(git ls-remote "$REPO_URL" HEAD | awk '{print $1}')

    if [ -z "$COMMIT" ]; then
        echo "ERROR: Failed to fetch latest commit SHA"
        exit 1
    fi
    echo "    Latest commit: $COMMIT"
fi

# --- Step 2: Fetch versionName and versionCode from build.gradle in that tree ---
echo "==> Fetching build.gradle from commit $COMMIT..."
BUILD_GRADLE=$(curl -sL "$RAW_URL/$COMMIT/build.gradle")

if [ -z "$BUILD_GRADLE" ]; then
    echo "ERROR: Failed to fetch build.gradle from GitHub"
    exit 1
fi

VERSION_CODE=$(echo "$BUILD_GRADLE" | grep -m1 'versionCode ' | sed 's/.*versionCode\s*\([0-9]\+\).*/\1/')
VERSION_NAME=$(echo "$BUILD_GRADLE" | grep -m1 'versionName ' | sed 's/.*versionName\s*["'\''"]*\([^"'\''"]*\).*/\1/')

if [ -z "$VERSION_CODE" ] || [ -z "$VERSION_NAME" ]; then
    echo "ERROR: Failed to parse version from build.gradle"
    echo "  versionCode=$VERSION_CODE versionName=$VERSION_NAME"
    exit 1
fi
echo "    versionCode: $VERSION_CODE"
echo "    versionName: $VERSION_NAME"

# --- Step 3: Reduce Builds to a single entry pointing at our commit ---
# Keeps the last upstream entry (current sudo:/gradle:) and drops the rest, so
# `fdroid build app:VC` matches one entry instead of looping over all of them.
META="$HOME/fdroiddata/metadata/app.murinelauncher.yml"
if [ ! -f "$META" ]; then
    echo "ERROR: Metadata file not found: $META"
    exit 1
fi

git -C "$HOME/fdroiddata" checkout -- metadata/app.murinelauncher.yml 2>/dev/null \
    || echo "    (metadata not tracked by git, editing in place)"

python3 - "$META" "$COMMIT" "$VERSION_CODE" "$VERSION_NAME" <<'PY'
import re, sys

path, commit, vcode, vname = sys.argv[1:5]
lines = open(path).read().split('\n')

starts = [i for i, l in enumerate(lines) if re.match(r'\s*-\s*versionName:', l)]
if not starts:
    sys.exit('ERROR: no Builds entries found in ' + path)

start = starts[-1]
end = next((i for i in range(start + 1, len(lines)) if re.match(r'\S', lines[i])), len(lines))
block = lines[start:end]

def put(key, value):
    for i, l in enumerate(block):
        m = re.match(r'(\s*(?:-\s*)?%s:\s*).*' % key, l)
        if m:
            block[i] = m.group(1) + value
            return
    sys.exit('ERROR: key %s not found in last Builds entry' % key)

put('versionName', "'%s'" % vname)
put('versionCode', vcode)
put('commit', commit)

# keep only this one entry
lines = lines[:starts[0]] + block + lines[end:]

# keep CurrentVersion in sync, otherwise lint warns it is older than the build entry
for i, l in enumerate(lines):
    if l.startswith('CurrentVersion:'):
        lines[i] = 'CurrentVersion: %s' % vname
    elif l.startswith('CurrentVersionCode:'):
        lines[i] = 'CurrentVersionCode: %s' % vcode

open(path, 'w').write('\n'.join(lines))
print('    Builds reduced to 1 entry -> versionCode %s @ %s' % (vcode, commit[:10]))
PY

# --- Step 4: Clean previous artifacts so nothing stale can be mistaken for this build ---
UNSIGNED_DIR="$HOME/fdroiddata/unsigned"
for f in "$UNSIGNED_DIR"/app.murinelauncher_${VERSION_CODE}.*; do
    if [ -f "$f" ]; then
        echo "    Removing old artifact: $f"
        rm -f "$f"
    fi
done

APK="$HOME/fdroiddata/build/app.murinelauncher/build/outputs/apk/aospWithoutQuickstep/release/app.murinelauncher-aosp-withoutQuickstep-release-unsigned.apk"
if [ -f "$APK" ]; then
    echo "    Removing old APK: $APK"
    rm -f "$APK"
fi

# --- Step 5: Run fdroid build inside Docker ---
# fdroid exits non-zero when the comparison against the published APK fails, expected
# for any unreleased commit; step 6 decides success instead. --cpuset-cpus (not --cpus)
# is what actually changes availableProcessors(); the metadata's sudo: cap is skipped.
echo "==> Starting Docker fdroid build (pinned to $CPUS CPUs)..."
BUILD_START=$(date +%s)
set +e
docker run --rm -u vagrant --cpuset-cpus="0-$((CPUS - 1))" -e VC="$VERSION_CODE" \
  --entrypoint /bin/bash \
  -v ~/fdroiddata:/build:z \
  -v ~/fdroidserver:/home/vagrant/fdroidserver:Z \
  registry.gitlab.com/fdroid/fdroidserver:buildserver \
  -c '. /etc/profile
export PATH="$fdroidserver:$PATH" PYTHONPATH="$fdroidserver"
export JAVA_HOME=$(java -XshowSettings:properties -version 2>&1 > /dev/null | grep "java.home" | awk -F"=" "{print \$2}" | tr -d " ")
cd /build
echo "CPUs visible to the build: $(nproc)"
fdroid readmeta
fdroid rewritemeta app.murinelauncher
fdroid lint app.murinelauncher
fdroid build "app.murinelauncher:$VC"
exit'
DOCKER_EXIT=$?
set -e
echo "==> Docker exited with code $DOCKER_EXIT"

# --- Step 6: Copy APK to output directory (with freshness check) ---
SKEW=5
if [ -f "$APK" ]; then
    APK_MTIME=$(stat -c %Y "$APK")
    if [ "$APK_MTIME" -lt "$(( BUILD_START - SKEW ))" ]; then
        echo "WARNING: APK predates this build (built $(( BUILD_START - APK_MTIME ))s before it started)."
        echo "         It was not generated by this run."
        echo "         Path: $APK"
        exit 1
    fi
    cp "$APK" "$OUTPUT_DIR/"
    echo "==> SUCCESS (ignore the verification errors above): APK copied to $OUTPUT_DIR/"
else
    echo "ERROR: APK not found at expected path:"
    echo "  $APK"
    echo "Listing available files under build output dir:"
    find "$HOME/fdroiddata/build/app.murinelauncher/build/outputs/" -name "*.apk" 2>/dev/null || echo "  (no apk files found)"
    exit 1
fi

exit 0
}
