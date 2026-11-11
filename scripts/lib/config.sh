# Sourced by the build scripts. Reads Config/Signing.local.xcconfig ("KEY = value" lines).

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CONFIG_FILE="$ROOT/Config/Signing.local.xcconfig"

xcconfig_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*\$/\1/p" "$CONFIG_FILE" | head -n 1
}

require_setting() {
  if [ -z "${!1:-}" ]; then
    echo "error: $1 is missing in $CONFIG_FILE" >&2
    return 1
  fi
}

# load_signing_config debug|release|notarize
# Sets CLAMDOWN_BUNDLE_ID, and SIGN_IDENTITY (debug, release) or CLAMDOWN_NOTARY_PROFILE (notarize).
load_signing_config() {
  local mode="$1"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "error: $CONFIG_FILE is missing." >&2
    echo "Copy Config/Signing.xcconfig.example to Config/Signing.local.xcconfig and fill in your values." >&2
    return 1
  fi
  CLAMDOWN_BUNDLE_ID=$(xcconfig_value CLAMDOWN_BUNDLE_ID)
  require_setting CLAMDOWN_BUNDLE_ID || return 1
  if ! [[ "$CLAMDOWN_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "error: CLAMDOWN_BUNDLE_ID may contain only letters, digits, dots and dashes" >&2
    return 1
  fi
  case "$mode" in
    debug)
      SIGN_IDENTITY=$(xcconfig_value CLAMDOWN_DEV_SIGN_IDENTITY)
      require_setting SIGN_IDENTITY || return 1
      ;;
    release|notarize)
      if [[ "$CLAMDOWN_BUNDLE_ID" == com.example.* ]]; then
        echo "error: set a real CLAMDOWN_BUNDLE_ID in $CONFIG_FILE before a release build" >&2
        return 1
      fi
      if [ "$mode" = release ]; then
        SIGN_IDENTITY=$(xcconfig_value CLAMDOWN_SIGN_IDENTITY)
        require_setting SIGN_IDENTITY || return 1
      else
        CLAMDOWN_NOTARY_PROFILE=$(xcconfig_value CLAMDOWN_NOTARY_PROFILE)
        require_setting CLAMDOWN_NOTARY_PROFILE || return 1
      fi
      ;;
    *)
      echo "error: unknown mode '$mode'" >&2
      return 1
      ;;
  esac
}
