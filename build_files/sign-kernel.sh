#!/usr/bin/env bash
set -euo pipefail

log() { echo "[custom-kernel] $*"; }
error() { echo "[custom-kernel] Error: $*"; exit 1; }

SECURE_TMP=$(mktemp -d -t MOK.XXXXXX)
SIGNING_KEY="$SECURE_TMP/MOK.priv"
SIGNING_CERT="/workspace/build_files/MOK.pem"
MOK_CERT="/usr/share/cert/MOK.der"

cleanup() {
    rm -rf "$SECURE_TMP"
}
trap cleanup EXIT

log "Extracting and validating keys..."
if [[ "${KERNEL_SECRET:-}" == *'\n'* ]]; then
    printf '%b' "${KERNEL_SECRET//\\n/$'\n'}" > "$SIGNING_KEY"
else
    printf '%s' "${KERNEL_SECRET:-}" > "$SIGNING_KEY"
fi
chmod 600 "$SIGNING_KEY"

openssl pkey -in "$SIGNING_KEY" -noout >/dev/null 2>&1 || error "Invalid private key"
openssl x509 -in "$SIGNING_CERT" -noout >/dev/null 2>&1 || error "Invalid X509 cert"

KERNEL_DIR="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -name "[0-9]*" | sort -V | tail -n 1)"
[[ -n "$KERNEL_DIR" ]] || error "No kernel directory found"
KERNEL_VER="$(basename "$KERNEL_DIR")"
VMLINUZ="$KERNEL_DIR/vmlinuz"

log "Signing kernel: $KERNEL_VER"
SIGNED_VMLINUZ=$(mktemp)
sbsign --key "$SIGNING_KEY" --cert "$SIGNING_CERT" --output "$SIGNED_VMLINUZ" "$VMLINUZ"
install -m 0644 "$SIGNED_VMLINUZ" "$VMLINUZ"
rm -f "$SIGNED_VMLINUZ"

SIGN_FILE="$KERNEL_DIR/build/scripts/sign-file"
[[ -x "$SIGN_FILE" ]] || error "sign-file missing or not executable"

sign_worker() {
    local mod="$1" sf="$2" key="$3" cert="$4" raw
    case "$mod" in
        *.ko)     "$sf" sha256 "$key" "$cert" "$mod" ;;
        *.ko.xz)  raw="${mod%.xz}";  xz -d -q "$mod";       "$sf" sha256 "$key" "$cert" "$raw"; xz -z -q -T0 "$raw" ;;
        *.ko.zst) raw="${mod%.zst}"; zstd -d -q --rm "$mod"; "$sf" sha256 "$key" "$cert" "$raw"; zstd -q -T0 --rm "$raw" ;;
        *.ko.gz)  raw="${mod%.gz}";  gzip -d -q -f "$mod";  "$sf" sha256 "$key" "$cert" "$raw"; gzip -q -f "$raw" ;;
    esac
}
export -f sign_worker

log "Signing modules in parallel..."
find "$KERNEL_DIR" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" -o -name "*.ko.gz" \) -print0 | \
    xargs -0 -P "$(nproc)" -I {} bash -c 'sign_worker "$1" "$2" "$3" "$4"' _ {} "$SIGN_FILE" "$SIGNING_KEY" "$SIGNING_CERT"

depmod -b / -a "$KERNEL_VER"

log "Configuring MOK enrollment service..."
mkdir -p /usr/share/cert /usr/lib/systemd/system
openssl x509 -in "$SIGNING_CERT" -outform DER -out "$MOK_CERT"

SERVICE="/usr/lib/systemd/system/mok-enroll.service"
echo "[Unit]" > "$SERVICE"
echo "Description=Enroll MOK key after GUI starts" >> "$SERVICE"
echo "ConditionPathExists=!/etc/mok_successfully_enrolled.lock" >> "$SERVICE"
echo "After=graphical.target" >> "$SERVICE"
echo "" >> "$SERVICE"
echo "[Service]" >> "$SERVICE"
echo "Type=oneshot" >> "$SERVICE"
echo "RemainAfterExit=yes" >> "$SERVICE"
echo "ExecStart=/bin/bash -c 'yes universalblue | mokutil --import /usr/share/cert/MOK.der && touch /etc/.mok_successfully_enrolled.lock'" >> "$SERVICE"
echo "" >> "$SERVICE"
echo "[Install]" >> "$SERVICE"
echo "WantedBy=graphical.target" >> "$SERVICE"

chmod 0644 "$SERVICE"
mkdir -p /usr/lib/systemd/system/sysinit.target.wants
ln -sf "$SERVICE" /usr/lib/systemd/system/sysinit.target.wants/mok-enroll.service

sbverify --cert "$SIGNING_CERT" "$VMLINUZ" >/dev/null 2>&1 || error "Verification failed."
log "Kernel signing complete."
