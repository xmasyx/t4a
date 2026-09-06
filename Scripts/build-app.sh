#!/bin/bash
# Builds a T4A.app — the thing that actually gets opened.
#
#   Scripts/build-app.sh              the BENCH bundle  -> dist/T4A.app
#   Scripts/build-app.sh bench        the same, said out loud
#   Scripts/build-app.sh debug        an unoptimised one -> dist/T4A.app
#   Scripts/build-app.sh release      the SHIPPED one    -> dist-release/T4A.app
#   Scripts/build-app.sh install      the SHIPPED one    -> /Applications/T4A.app
#
# A verification on .build/release closes nothing: the copy in dist/ is the one
# that runs, so the bundle is rebuilt before anyone is told to look.
#
# Three modes and not two, because of ISC-128. The test channel — the door the
# benches drive the app through — is compiled only under `DEBUG` or an explicit
# `-DT4A_TESTABLE`, and the shipped binary gets neither. But the Fase 3 numbers
# (GPU 0.142 ms, CPU 0.079 ms) were measured on an OPTIMISED build, and an
# unoptimised one would report frame times that are not the product's. So the
# bench bundle is release optimisation PLUS the door, in its own scratch
# directory so the two release builds do not evict each other, and
# `dist-release/T4A.app` is the one with no door at all.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-bench}"
BUNDLE_ID="dev.t4a.terminal"
VERSION="0.1.0"

case "$MODE" in
  bench)
    CONFIG=release
    SCRATCH=(--scratch-path .build/testable)
    FLAGS=(-Xswiftc -DT4A_TESTABLE)
    APP="dist/T4A.app"
    ;;
  debug)
    CONFIG=debug
    SCRATCH=()
    FLAGS=()
    APP="dist/T4A.app"
    ;;
  release)
    CONFIG=release
    SCRATCH=()
    FLAGS=()
    APP="dist-release/T4A.app"
    ;;
  install)
    # The one he opens. A bundle run from dist/ steals the login item and never
    # appears in Spotlight or the Dock the way the other apps do, so the copy in
    # /Applications is a release build: no test channel, like a real app.
    CONFIG=release
    SCRATCH=()
    FLAGS=()
    APP="/Applications/T4A.app"
    ;;
  *)
    echo "usage: $0 [bench|debug|release|install]" >&2
    exit 2
    ;;
esac

# The install refuses to ship an ad-hoc signature. On 2026-09-05 the login
# keychain had lost every signing identity and `install` quietly signed the
# /Applications copy ad hoc — a new identity, so every folder permission he had
# granted would have been asked again (the 31/08 defect, back). The identity is
# checked BEFORE building, because by the time the signing block runs the
# bundle is already in place. Re-import the backed-up t4a.p12 (see
# Scripts/make-signing-cert.sh) or, knowingly, T4A_ALLOW_ADHOC=1.
if [ "$MODE" = "install" ] && [ -z "${T4A_ALLOW_ADHOC:-}" ] \
   && ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"T4A Dev"'; then
  echo "install refused: no \"T4A Dev\" signing identity in the keychain." >&2
  echo "An ad-hoc /Applications/T4A.app resets every folder permission. Re-import the backed-up t4a.p12, or set T4A_ALLOW_ADHOC=1 to do it anyway." >&2
  exit 1
fi

# Every shipped shell script is read by a parser before it is shipped. A file
# no compiler looks at still has to be looked at by something.
for script in Sources/T4A/Integration/bash/*.bash Scripts/*.sh; do
  [ -e "$script" ] || continue
  bash -n "$script"
done
for script in Sources/T4A/Integration/zsh/t4a-integration.zsh \
              Sources/T4A/Integration/zsh/.z*; do
  [ -e "$script" ] || continue
  zsh -n "$script"
done
if command -v fish >/dev/null 2>&1; then
  fish --no-execute Sources/T4A/Integration/fish/fish/vendor_conf.d/t4a-integration.fish
fi

echo "==> $MODE: swift build -c $CONFIG ${FLAGS[*]:-}"
swift build -c "$CONFIG" ${SCRATCH[@]+"${SCRATCH[@]}"} ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${SCRATCH[@]+"${SCRATCH[@]}"} ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)"

# Replacing a bundle that is open pulls the resources out from under a live
# process: it survives on held inodes until it needs a file it no longer has.
# NoSleep skips the install in that case rather than gamble, and so does this.
if [ "$MODE" = "install" ] && pgrep -f "^/Applications/T4A.app/Contents/MacOS/T4A" >/dev/null 2>&1; then
  APP="dist-release/T4A.app"
  echo "==> T4A is running from /Applications: installing to $APP instead."
  echo "    Quit it and re-run \"$0 install\" to replace the installed copy."
fi

echo "==> assembling $APP"
# ── Le cartelle di lavoro vivono FUORI dal progetto (2026-08-30, sua segnalazione)
#
# Cercando «t4a» la ricerca di macOS restituiva dodici voci identiche: un
# `dist/T4A.app` per worktree, tutti indistinguibili dalla copia installata.
# Spotlight indicizza per percorso REALE e ignora `.metadata_never_index`
# (provato: il bundle resta nell'indice, e rinominato viene reindicizzato), ma
# non segue i symlink — quindi `dist/` e `dist-release/` sono collegamenti a
# $TMPDIR, i 71 riferimenti degli script continuano a funzionare, e la sola
# T4A che compare nella ricerca è quella in /Applications.
#
# La sonda: `mdfind -name T4A | grep '\.app$'` deve stampare una riga sola.
ensure_build_link() {
  local name="$1"
  local link="$name"
  local target="${TMPDIR:-/tmp}/$(basename "$PWD")-$name"
  mkdir -p "$target"
  if [ -L "$link" ]; then return 0; fi
  if [ -d "$link" ]; then
    # una directory vera qui rimette i duplicati nell'indice: si svuota nel target
    find "$link" -mindepth 1 -maxdepth 1 -exec mv {} "$target/" \; 2>/dev/null || true
    rmdir "$link" 2>/dev/null || { echo "⚠︎ $link non vuota, resta una directory vera"; return 0; }
  fi
  ln -s "$target" "$link"
}
case "$APP" in
  dist/*)         ensure_build_link dist ;;
  dist-release/*) ensure_build_link dist-release ;;
esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/T4A" "$APP/Contents/MacOS/T4A"

# The integration shims travel inside the bundle, read-only. Nothing under the
# user's home is written or edited (ISC-16).
cp -R Sources/T4A/Integration "$APP/Contents/Resources/Integration"

# The icon is a committed asset, not a drawing redone on every build:
# `Scripts/icon.sh` regenerates it from ImageMagick, this only packs it. Without
# an icon the Dock falls back to the blank sheet of paper, which is how you tell
# a real app from a binary someone put in a folder.
if [ -f Icon/icon-1024.png ]; then
  ICONSET=".build/T4A.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for px in 16 32 128 256 512; do
    sips -z "$px" "$px" Icon/icon-1024.png \
      --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z "$((px * 2))" "$((px * 2))" Icon/icon-1024.png \
      --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/T4A.icns"
else
  echo "warning: Icon/icon-1024.png is missing; the bundle ships without an icon"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>T4A</string>
  <key>CFBundleDisplayName</key><string>T4A</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>T4A</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>T4A</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <!-- t4a://focus?session=<uuid> lets something outside the app come back to
       one pane, the way ITERM_SESSION_ID plus AppleScript does for iTerm.
       Without this key the handler in main.swift is never called. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>t4a</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Local notifications need a signed bundle with a stable identifier — and the
# system permissions (TCC: Desktop, Documents, Downloads) follow the signing
# IDENTITY, not the bundle id. An ad-hoc signature is a new identity at every
# rebuild, which is why the app kept asking for the same folders again (his
# report, 2026-08-24). A self-signed certificate in the login keychain is the
# same identity for ten years: `Scripts/make-signing-cert.sh`, once.
IDENTITY="T4A Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "warning: signing with \"$IDENTITY\" failed"
  echo "==> signed with \"$IDENTITY\" (permissions survive the rebuild)"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc signing failed; notifications may not appear"
  echo "==> ad-hoc signature: run Scripts/make-signing-cert.sh once, or macOS keeps re-asking for folder access"
fi

# The gate, run on the artefact and not on the intention: a shipped binary that
# still answers the channel is the defect ISC-128 exists for, and it costs two
# greps to know rather than believe.
#
# NOT the verb names. `strings` cannot see them in EITHER build: Swift stores an
# ASCII literal of fifteen bytes or fewer inline in the code as a small string,
# so `text`, `key`, `cells` and `typekey` are absent from the string table of
# the bench bundle too — a grep for them comes back zero when the channel is
# very much there, which is a green light wired to nothing. (And `approve` and
# `cells` DO appear in the release binary for honest reasons: the classifier's
# word list and a JSON key.) What actually separates the two builds is the
# environment variable that arms the channel — sixteen bytes, so it lands in
# the string table — and the symbols of the type itself.
ENVVAR="$(strings -a "$APP/Contents/MacOS/T4A" | grep -c 'T4A_TEST_CHANNEL' || true)"
SYMBOLS="$(nm -pa "$APP/Contents/MacOS/T4A" 2>/dev/null | grep -c '11TestChannel' || true)"
if [ "$MODE" = "release" ] || [ "$MODE" = "install" ]; then
  if [ "$ENVVAR" != "0" ] || [ "$SYMBOLS" != "0" ]; then
    echo "REFUSING: the release binary still carries the test channel" \
         "(T4A_TEST_CHANNEL=$ENVVAR symbols=$SYMBOLS)" >&2
    exit 1
  fi
  echo "==> no test channel in the binary (T4A_TEST_CHANNEL=0, symbols=0)"
else
  if [ "$ENVVAR" = "0" ] || [ "$SYMBOLS" = "0" ]; then
    echo "REFUSING: a $MODE bundle without the test channel drives nothing" \
         "(T4A_TEST_CHANNEL=$ENVVAR symbols=$SYMBOLS)" >&2
    exit 1
  fi
  echo "==> test channel present, as a $MODE build should be (symbols=$SYMBOLS)"
fi

echo "==> $APP"
codesign -dv "$APP" 2>&1 | sed -n '1,3p' || true
echo "Quit and reopen the app to pick this build up."
