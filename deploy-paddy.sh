#!/bin/bash
# Motus — direct wireless install to Paddy (iPad Pro 11" M5) via devicectl.
# Release config so audio doesn't starve under Debug.
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

REPO_DIR="/Users/admin/motus-xl-ios"
TEAM_ID="9TUXM4MBAV"
SCHEME="MotusXL"
PROJECT="$REPO_DIR/MotusXL.xcodeproj"
ARCHIVE_PATH="/tmp/MotusXL-Paddy.xcarchive"
EXPORT_PATH="/tmp/MotusXLPaddyExport"
PADDY_ID="FB14BC29-FBBC-591F-A000-F988ECC42ABB"

API_KEY_ID="FV5WR6A335"
API_ISSUER="063d077f-1dbb-4904-8ead-515fe477da68"
API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"

cd "$REPO_DIR"
echo ">> xcodegen..."; xcodegen generate
echo ">> Stripping xattrs..."; xattr -cr "$REPO_DIR/Sources" 2>/dev/null || true; xattr -cr "$REPO_DIR/Resources" 2>/dev/null || true
BUILD_NUMBER=$(date +%s)
echo ">> Archiving $SCHEME (Release) build $BUILD_NUMBER..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE_PATH" archive \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -allowProvisioningUpdates \
    -authenticationKeyPath "$API_KEY_PATH" -authenticationKeyID "$API_KEY_ID" -authenticationKeyIssuerID "$API_ISSUER" \
    CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -quiet

echo ">> Exporting (method=development)..."
cat > /tmp/MotusXLPaddyExportOptions.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>development</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>9TUXM4MBAV</string>
    <key>compileBitcode</key><false/>
    <key>stripSwiftSymbols</key><true/>
</dict></plist>
PLIST

rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist /tmp/MotusXLPaddyExportOptions.plist -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates -authenticationKeyPath "$API_KEY_PATH" \
    -authenticationKeyID "$API_KEY_ID" -authenticationKeyIssuerID "$API_ISSUER"

IPA_DST="$HOME/Desktop/Motus-paddy.ipa"
cp "$EXPORT_PATH/Motus.ipa" "$IPA_DST"
echo ">> Installing to Paddy..."
xcrun devicectl device install app --device "$PADDY_ID" "$IPA_DST"
echo "✅ Motus build $BUILD_NUMBER installed on Paddy"
