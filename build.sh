#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-1.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:-12}"

# The data pack bundled into the app. To ship new data, point these at a
# pack-* release. If the schema changed, also bump SCHEMA_VERSION in pike-export
# and BundledPack.supportedSchema.
PACK_TAG="pack-20260715-schema5"
PACK_SHA256="0b80af782c63809296da1efa4a1dd50acc94008b69d474641746b0d655342645"
PACK_PATH="Pike/Resources/pike.sqlite"

PROJECT="Pike.xcodeproj"
SCHEME="Pike"
BUILD_DIR="$(pwd)/build"
ARCHIVE_PATH="$BUILD_DIR/Pike.xcarchive"
EXPORT_OPTIONS="ExportOptions.plist"

# Upload auth: an App Store Connect API key. Set the key id and issuer id and
# put the .p8 in ~/.appstoreconnect/private_keys/, where altool looks for it.
ASC_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-}"
ASC_ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID:-}"
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

asc_key_available() {
    [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -f "$ASC_KEY_PATH" ]
}

usage() {
    echo "Usage: $0 [--fetch-pack | --upload]"
    echo ""
    echo "  Env overrides:"
    echo "    VERSION=<marketing version> (default: $VERSION)"
    echo "    BUILD_NUMBER=<build number> (default: $BUILD_NUMBER)"
    echo ""
    echo "  (no args)    Simulator build (debug)"
    echo "  --fetch-pack Download the pinned data pack (needed before building in Xcode)"
    echo "  --upload     Archive + export + upload to App Store Connect"
}

# Pretty-print xcodebuild output when xcbeautify is installed.
run_xcodebuild() {
    if command -v xcbeautify &> /dev/null; then
        xcodebuild "$@" | xcbeautify
    else
        xcodebuild "$@"
    fi
}

pack_is_current() {
    [ -f "$PACK_PATH" ] && [ "$(shasum -a 256 "$PACK_PATH" | cut -d' ' -f1)" = "$PACK_SHA256" ]
}

fetch_pack() {
    if pack_is_current; then
        echo "==> Data pack $PACK_TAG already in place."
        return
    fi
    echo "==> Downloading data pack $PACK_TAG..."
    gh release download "$PACK_TAG" --repo tldev/pike --pattern pike.sqlite --output "$PACK_PATH" --clobber
    if ! pack_is_current; then
        echo "ERROR: $PACK_PATH does not match PACK_SHA256"
        rm -f "$PACK_PATH"
        exit 1
    fi
    echo "==> Data pack ready: $PACK_PATH"
}

simulator_build() {
    echo "==> Building for simulator..."
    run_xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination 'generic/platform=iOS Simulator' \
        build
    echo "==> Simulator build succeeded."
}

archive() {
    echo "==> Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    echo "==> Using MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
    echo "==> Archiving..."
    run_xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        SENTRY_DSN="${SENTRY_DSN:-}"
    echo "==> Archive succeeded: $ARCHIVE_PATH"
}

export_ipa() {
    echo "==> Exporting IPA..."
    EXPORT_ARGS=(
        -archivePath "$ARCHIVE_PATH"
        -exportOptionsPlist "$EXPORT_OPTIONS"
        -exportPath "$BUILD_DIR"
        -allowProvisioningUpdates
    )
    if asc_key_available; then
        echo "==> Authenticating export with App Store Connect API key $ASC_KEY_ID"
        EXPORT_ARGS+=(
            -authenticationKeyPath "$ASC_KEY_PATH"
            -authenticationKeyID "$ASC_KEY_ID"
            -authenticationKeyIssuerID "$ASC_ISSUER_ID"
        )
    fi
    run_xcodebuild -exportArchive "${EXPORT_ARGS[@]}"

    IPA_PATH=$(find "$BUILD_DIR" -name "*.ipa" -maxdepth 1 | head -1)
    if [ -z "$IPA_PATH" ]; then
        echo "ERROR: No IPA found in $BUILD_DIR"
        exit 1
    fi
    echo "==> Export succeeded: $IPA_PATH"
}

upload_dsyms() {
    echo "==> Uploading dSYMs to Sentry..."
    DSYM_PATH="$ARCHIVE_PATH/dSYMs"
    if [ ! -d "$DSYM_PATH" ]; then
        echo "WARNING: No dSYMs found at $DSYM_PATH — skipping Sentry upload."
        return
    fi
    if ! command -v sentry-cli &> /dev/null; then
        echo "WARNING: sentry-cli not found — skipping dSYM upload."
        return
    fi
    # Org and project come from SENTRY_ORG and SENTRY_PROJECT.
    if sentry-cli debug-files upload "$DSYM_PATH"; then
        echo "==> dSYM upload succeeded."
    else
        echo "WARNING: dSYM upload failed, continuing without it."
    fi
}

upload() {
    IPA_PATH=$(find "$BUILD_DIR" -name "*.ipa" -maxdepth 1 | head -1)
    if [ -z "$IPA_PATH" ]; then
        echo "ERROR: No IPA found in $BUILD_DIR"
        exit 1
    fi

    echo "==> Uploading to App Store Connect..."

    if ! asc_key_available; then
        echo "ERROR: Set APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID,"
        echo "and put AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys/."
        exit 1
    fi

    xcrun altool --upload-app \
        --type ios \
        --file "$IPA_PATH" \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID"
    echo "==> Upload succeeded!"
    echo ""
    echo "Next: Go to App Store Connect to select the build and submit for review."
}

case "${1:-}" in
    --fetch-pack)
        fetch_pack
        ;;
    --upload)
        fetch_pack
        archive
        upload_dsyms
        export_ipa
        upload
        ;;
    --help|-h)
        usage
        ;;
    "")
        fetch_pack
        simulator_build
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
esac
