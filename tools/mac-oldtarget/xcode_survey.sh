#!/bin/bash
# xcode_survey.sh <macos version> <out file>
#
# For every Xcode in /Applications: its version, its macOS SDK, the SDK's
# MinimumDeploymentTarget, and what a test compile for that macOS version
# actually produces (x86_64). Then picks the newest Xcode that builds for
# the requested version without raising it, and writes its path to
# <out file>. Test branch only; does no distributed.net work.

WANT="$1"
OUT="$2"
WORK=$(mktemp -d)
printf 'int main(void) { return 0; }\n' > "$WORK/t.c"

# version compare: prints 1 if $1 <= $2
le() { python3 -c "import sys; a=[int(x) for x in sys.argv[1].split('.')]; b=[int(x) for x in sys.argv[2].split('.')]; n=max(len(a),len(b)); a+=[0]*(n-len(a)); b+=[0]*(n-len(b)); print(1 if a<=b else 0)" "$1" "$2"; }

echo "Wanted minimum macOS: $WANT"
echo "Runner: $(sw_vers -productVersion) $(uname -m)"
echo
best=""
best_ver=""
for X in /Applications/Xcode*.app; do
  [ -d "$X/Contents/Developer" ] || continue
  [ -L "$X" ] && continue
  export DEVELOPER_DIR="$X/Contents/Developer"
  xver=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
  sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)
  sdkver=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)
  mindt=$(python3 - "$sdk" <<'EOF'
import json, plistlib, sys, os
p = sys.argv[1]
v = None
try:
    d = json.load(open(os.path.join(p, 'SDKSettings.json')))
    v = d['SupportedTargets']['macosx']['MinimumDeploymentTarget']
except Exception:
    try:
        d = plistlib.load(open(os.path.join(p, 'SDKSettings.plist'), 'rb'))
        v = d['SupportedTargets']['macosx']['MinimumDeploymentTarget']
    except Exception:
        v = '?'
print(v)
EOF
)
  rm -f "$WORK/t"
  warn=$(cc -arch x86_64 -mmacosx-version-min="$WANT" -o "$WORK/t" "$WORK/t.c" 2>&1 | tr '\n' ' ')
  if [ -f "$WORK/t" ]; then
    minos=$(otool -l "$WORK/t" | awk '/LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION/{f=1} f&&/(version|minos) /{print $2; exit}')
  else
    minos="(build failed)"
  fi
  echo "Xcode $xver  ($X)"
  echo "  macOS SDK $sdkver, MinimumDeploymentTarget $mindt"
  echo "  test build for $WANT: minos $minos${warn:+  messages: $warn}"
  if [ "$minos" = "$WANT" ] && [ -z "$warn" ]; then
    if [ -z "$best" ] || [ "$(le "$best_ver" "$xver")" = 1 ]; then
      best="$X"
      best_ver="$xver"
    fi
  fi
done
echo
if [ -n "$best" ]; then
  echo "Newest Xcode that builds for macOS $WANT: $best_ver ($best)"
  echo "$best" > "$OUT"
else
  echo "No Xcode on this runner builds for macOS $WANT without changing it"
  : > "$OUT"
fi
rm -rf "$WORK"
