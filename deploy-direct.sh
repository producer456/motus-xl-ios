#!/bin/bash
# Motus — build, ad-hoc sign, publish to local Tailscale OTA serve dir.
# Open the install page in Safari on any tailnet iOS device and tap Install.
set -e
export PATH="/opt/homebrew/bin:$PATH"
REPO_DIR="/Users/admin/motus-ios"
TEAM_ID="9TUXM4MBAV"
SCHEME="Motus"
BUNDLE_ID="com.legionstage.motus"
APP_TITLE="Motus"
ARCHIVE_PATH="/tmp/Motus-direct.xcarchive"
EXPORT_PATH="/tmp/MotusAdHocExport"
API_KEY="FV5WR6A335"
API_ISSUER="063d077f-1dbb-4904-8ead-515fe477da68"
KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY}.p8"
SERVE_ROOT="$HOME/Sites/ios-ota"
SERVE_DIR="$SERVE_ROOT/$BUNDLE_ID"
TS_CLI=$(command -v tailscale || echo "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
TAILNET_HOST=$("$TS_CLI" status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
[ -n "$TAILNET_HOST" ] || { echo "ERR: could not resolve tailnet host"; exit 1; }
cd "$REPO_DIR"
BUILD_NUMBER=$(date +%s)
echo ">> xcodegen..."; xcodegen generate >/dev/null
echo ">> archiving Motus (build $BUILD_NUMBER)..."
rm -rf "$ARCHIVE_PATH"
xcodebuild -project Motus.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE_PATH" archive \
  -allowProvisioningUpdates -authenticationKeyID "$API_KEY" -authenticationKeyIssuerID "$API_ISSUER" \
  -authenticationKeyPath "$KEY_FILE" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -quiet
echo ">> exporting ad-hoc IPA..."
cat > /tmp/MotusAdHocExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>ad-hoc</string>
<key>teamID</key><string>${TEAM_ID}</string>
<key>signingStyle</key><string>automatic</string>
<key>compileBitcode</key><false/>
<key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PLIST
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist /tmp/MotusAdHocExportOptions.plist -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates -authenticationKeyID "$API_KEY" -authenticationKeyIssuerID "$API_ISSUER" \
  -authenticationKeyPath "$KEY_FILE"
IPA_SRC=$(ls "$EXPORT_PATH"/*.ipa | head -1)
[ -f "$IPA_SRC" ] || { echo "ERR: no IPA produced"; exit 1; }
echo ">> publishing to OTA hub..."
mkdir -p "$SERVE_DIR"; cp "$IPA_SRC" "$SERVE_DIR/app.ipa"
IPA_URL="https://$TAILNET_HOST/$BUNDLE_ID/app.ipa"
MANIFEST_URL="https://$TAILNET_HOST/$BUNDLE_ID/manifest.plist"
cat > "$SERVE_DIR/manifest.plist" <<MANIFEST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict>
<key>kind</key><string>software-package</string><key>url</key><string>$IPA_URL</string>
</dict></array>
<key>metadata</key><dict>
<key>bundle-identifier</key><string>$BUNDLE_ID</string>
<key>bundle-version</key><string>$BUILD_NUMBER</string>
<key>kind</key><string>software</string><key>title</key><string>$APP_TITLE</string>
</dict></dict></array></dict></plist>
MANIFEST
cat > "$SERVE_DIR/meta.json" <<META
{"bundle_id":"$BUNDLE_ID","title":"$APP_TITLE","build":"$BUILD_NUMBER","updated":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
META
cat > "$SERVE_DIR/install.html" <<HTML
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Install $APP_TITLE</title>
<style>body{font:16px/1.4 -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#111;color:#eee}.card{padding:2rem;text-align:center}a.btn{display:inline-block;padding:1rem 2rem;background:#06f;color:#fff;border-radius:.75rem;text-decoration:none;font-weight:600;margin-top:1rem}p{color:#888;font-size:.875rem;margin:.25rem 0}</style>
<div class="card"><h1>$APP_TITLE</h1><p>build $BUILD_NUMBER</p>
<a class="btn" href="itms-services://?action=download-manifest&url=$MANIFEST_URL">Install on this device</a>
<p style="margin-top:1.25rem">Open in Safari on the target iPad/iPhone, on the tailnet.</p></div>
HTML
[ -x /Users/admin/Sites/refresh-ota-hub.sh ] && /Users/admin/Sites/refresh-ota-hub.sh || true
echo "OK: https://$TAILNET_HOST/$BUNDLE_ID/install.html"
