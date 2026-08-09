# Shared helpers. Sourced, not executed.

RELEASE="raspios_lite_arm64-2026-06-19"
IMAGE_BASE="2026-06-18-raspios-trixie-arm64-lite"
MIRROR="https://downloads.raspberrypi.com/raspios_lite_arm64/images/${RELEASE}"

# The verified image lives inside the repo so the card can be re-burned with
# no internet connection, ever. (macOS purges its temp dirs on its own
# schedule - a cache there would silently disappear.)
CACHE="${UMIK_CACHE:-$PWD/cache}"
mkdir -p "$CACHE"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

# Every network fetch in this project goes through here. Certificate
# validation is mandatory and there is deliberately no way to turn it off:
# no -k, no --insecure, no --proto-default http.
fetch() {
    curl --fail --silent --show-error --location \
         --proto '=https' --proto-redir '=https' \
         --tlsv1.2 \
         "$@"
}
