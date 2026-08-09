#!/bin/bash
# Build Sift.app.
#
#   ./build-app.sh                  -> ./Sift.app
#   ./build-app.sh /Applications    -> installs there
#
# No Xcode required: swift build, PlistBuddy, sips, iconutil, osascript, codesign and lsregister
# all ship with the Command Line Tools. Gatekeeper: quarantine is applied by whatever *downloads*
# a file, so a locally built app just launches; zip it to a teammate and they get "Apple could not
# verify…" — the install path for others is `git pull && ./build-app.sh`, not a zip.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

DEST="${1:-$HERE}"
APP="$DEST/Sift.app"
PLIST="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ ! -x "$HERE/.venv/bin/python" ]]; then
  echo "build-app: no venv yet. See the setup comment at the top of dev.sh." >&2
  exit 1
fi

rm -rf "$APP"

echo "==> building the Swift shell"
( cd shell && swift build -c release )
BIN="$HERE/shell/.build/release/Sift"
[[ -x "$BIN" ]] || { echo "build-app: swift build produced no binary" >&2; exit 1; }

echo "==> assembling the bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sift"
# The engine is referenced, not copied: `git pull` then updates it without rebuilding the app,
# and the bundle stays ~1 MB. AppDelegate.engineRoot() resolves this symlink.
ln -sfn "$HERE" "$APP/Contents/Resources/engine-root"

echo "==> Info.plist"
set_plist() { $PB -c "Delete :$1" "$PLIST" 2>/dev/null || true; $PB -c "Add :$1 $2 $3" "$PLIST"; }
set_plist CFBundleExecutable          string  "Sift"
set_plist CFBundleIconFile            string  "AppIcon"
set_plist CFBundlePackageType         string  "APPL"
set_plist CFBundleIdentifier          string  "io.github.diamondplated.sift"
set_plist CFBundleName                string  "Sift"
set_plist CFBundleDisplayName         string  "Sift"
set_plist CFBundleShortVersionString  string  "0.1.0"
set_plist CFBundleVersion             string  "1"
set_plist LSMinimumSystemVersion      string  "13.0"
set_plist NSHumanReadableCopyright    string  "Engine Data Management"
set_plist NSHighResolutionCapable     bool    true
# WKWebView refuses plain http by default, including to 127.0.0.1. Without this the window loads
# blank with no useful error — a genuinely baffling failure mode.
$PB -c "Delete :NSAppTransportSecurity" "$PLIST" 2>/dev/null || true
$PB -c "Add :NSAppTransportSecurity dict" "$PLIST"
$PB -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST"

echo "==> declaring the formats macOS does not know"
# Parquet has NO system UTI — a real .parquet reports the dynamic `dyn.ah62d4rv4ge81a2pwsf40n7a`,
# synthesized from its extension. NDJSON likewise. `Imported` (not `Exported`) is correct: Apache
# and the NDJSON community own these formats; Sift only recognizes them.
$PB -c "Delete :UTImportedTypeDeclarations" "$PLIST" 2>/dev/null || true
$PB -c "Add :UTImportedTypeDeclarations array" "$PLIST"

$PB -c "Add :UTImportedTypeDeclarations:0 dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeIdentifier string org.apache.parquet.file" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeDescription string 'Apache Parquet File'" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeConformsTo array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeConformsTo:0 string public.data" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 string parquet" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:1 string parq" "$PLIST"

# NDJSON conforms to public.plain-text, NOT public.json — newline-delimited JSON is not valid JSON.
$PB -c "Add :UTImportedTypeDeclarations:1 dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeIdentifier string org.ndjson.ndjson" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeDescription string 'Newline-Delimited JSON'" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeConformsTo array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeConformsTo:0 string public.plain-text" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification:public.filename-extension array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification:public.filename-extension:0 string ndjson" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification:public.filename-extension:1 string jsonl" "$PLIST"

echo "==> document types"
$PB -c "Delete :CFBundleDocumentTypes" "$PLIST" 2>/dev/null || true
$PB -c "Add :CFBundleDocumentTypes array" "$PLIST"

# Rank Alternate for formats other apps legitimately own, so Sift appears in "Open With" without
# stealing .csv from Numbers or .xlsx from Excel.
add_doctype() { # index, name, rank
  $PB -c "Add :CFBundleDocumentTypes:$1 dict" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:CFBundleTypeName string '$2'" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:CFBundleTypeRole string Viewer" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:LSHandlerRank string $3" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:LSItemContentTypes array" "$PLIST"
}
add_uti() { $PB -c "Add :CFBundleDocumentTypes:$1:LSItemContentTypes:$2 string $3" "$PLIST"; }

add_doctype 0 "Tabular Data" Alternate
add_uti 0 0 public.comma-separated-values-text
add_uti 0 1 public.tab-separated-values-text
add_uti 0 2 public.json
add_uti 0 3 org.openxmlformats.spreadsheetml.sheet
add_uti 0 4 public.plain-text

# Owner for the ones nothing else claims.
add_doctype 1 "Columnar Data" Owner
add_uti 1 0 org.apache.parquet.file
add_uti 1 1 org.ndjson.ndjson

# Dropping a hive-partitioned directory or a Delta table is a daily workflow for this audience.
add_doctype 2 "Dataset Folder" Alternate
add_uti 2 0 public.folder

echo "==> icon"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
BASE="$WORK/icon.png"
# Three white bars tapering downward — a sieve — on the brand-orange rounded square, drawn with
# the Cocoa that ships in macOS. Bar y-centres are flipped (1 - cy): Cocoa's origin is bottom-left.
osascript -l JavaScript - "$BASE" <<'EOF' >/dev/null
ObjC.import('AppKit')
function run(argv) {
  const out = argv[0], size = 1024
  const rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, size, size, 8, 4, true, false, $.NSCalibratedRGBColorSpace, 0, 0)
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep))
  const pad = size * 0.055, r = size * 0.22
  $.NSColor.colorWithCalibratedRedGreenBlueAlpha(240/255, 83/255, 35/255, 1).setFill  // Engine orange
  $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(pad, pad, size - 2*pad, size - 2*pad), r, r).fill
  $.NSColor.whiteColor.setFill
  for (const [cy, hw, hh] of [[0.335, 0.300, 0.052], [0.500, 0.215, 0.052], [0.665, 0.130, 0.052]])
    $.NSBezierPath.fillRect($.NSMakeRect((0.5 - hw) * size, (1 - cy - hh) * size, 2 * hw * size, 2 * hh * size))
  rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $()).writeToFileAtomically(out, true)
}
EOF
for s in 16 32 128 256 512; do
  sips -z $s $s "$BASE" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BASE" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

echo "==> signing"
# Ad-hoc signing is mandatory on Apple Silicon — the kernel refuses unsigned arm64 executables. Sign
# AFTER assembling so the signature covers the edited Info.plist and the icon. Deliberately NO
# --options runtime: the hardened runtime's library validation would refuse the unsigned .so
# extension modules inside the Python venv, and without notarizing it buys nothing.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> registering with LaunchServices"
# Without this, "Open With" silently keeps showing the previous declarations.
"$LSREGISTER" -f "$APP" || true

echo
echo "Built $APP"
echo "  drop files anywhere in the window, on the Dock icon, or via File > Open"
echo "  engine: $APP/Contents/Resources/engine-root -> $HERE"
