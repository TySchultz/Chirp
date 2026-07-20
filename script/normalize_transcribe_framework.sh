#!/usr/bin/env bash
set -euo pipefail

FRAMEWORK_PATH="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/CTranscribe.framework"

case "$FRAMEWORK_PATH" in
  "$TARGET_BUILD_DIR"/*/CTranscribe.framework) ;;
  *)
    echo "Refusing to modify unexpected framework path: $FRAMEWORK_PATH" >&2
    exit 1
    ;;
esac

if [[ ! -f "$FRAMEWORK_PATH/Versions/A/CTranscribe" ]]; then
  echo "CTranscribe.framework was not embedded before normalization." >&2
  exit 1
fi

# transcribe.cpp v0.1.3's release zip stores framework symlinks as duplicated
# directories. Xcode then strips public headers while preserving a signature
# that sealed them, making strict bundle verification fail. Restore the normal
# versioned-framework layout and sign exactly the files that ship in the app.
rm -rf "$FRAMEWORK_PATH/Versions/Current"
ln -s A "$FRAMEWORK_PATH/Versions/Current"

rm -rf "$FRAMEWORK_PATH/CTranscribe" "$FRAMEWORK_PATH/Resources"
ln -s Versions/Current/CTranscribe "$FRAMEWORK_PATH/CTranscribe"
ln -s Versions/Current/Resources "$FRAMEWORK_PATH/Resources"

rm -rf "$FRAMEWORK_PATH/Versions/A/_CodeSignature"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
  SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
  fi
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$FRAMEWORK_PATH"
fi
