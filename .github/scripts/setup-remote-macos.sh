#!/usr/bin/env bash

set -Eeuo pipefail

REMOTE_MAC_PASSWORD="${REMOTE_MAC_PASSWORD:-}"

if [[ -z "$REMOTE_MAC_PASSWORD" ]]; then
  echo "::error::REMOTE_MAC_PASSWORD is not configured in the repository secrets."
  exit 1
fi

if (( ${#REMOTE_MAC_PASSWORD} < 8 )); then
  echo "::error::REMOTE_MAC_PASSWORD must contain at least 8 characters."
  exit 1
fi

# Apple's legacy VNC authentication only uses the first eight characters.
VNC_PASSWORD="${REMOTE_MAC_PASSWORD:0:8}"
ARD_KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
VNC_SETTINGS="/Library/Preferences/com.apple.VNCSettings.txt"

echo "Preparing Xcode project..."
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi
xcodegen generate

echo "Enabling the built-in macOS screen-sharing service..."
sudo "$ARD_KICKSTART" -deactivate >/dev/null 2>&1 || true
sudo "$ARD_KICKSTART" \
  -activate \
  -configure -access -on \
  -configure -allowAccessFor -allUsers \
  -configure -privs -all \
  -configure -clientopts -setvnclegacy -vnclegacy yes \
  -restart -agent -console

# Store the VNC password in the format expected by macOS Screen Sharing.
printf '%s\n' "$VNC_PASSWORD" | perl -we '
  BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA" }
  $_ = <>;
  chomp;
  s/^(.{8}).*/$1/;
  @p = unpack "C*", $_;
  foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) }
  print "\n";
' | sudo tee "$VNC_SETTINGS" >/dev/null
sudo chmod 600 "$VNC_SETTINGS"

sudo launchctl enable system/com.apple.screensharing >/dev/null 2>&1 || true
sudo launchctl kickstart -k system/com.apple.screensharing >/dev/null 2>&1 || \
  sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
sudo "$ARD_KICKSTART" -restart -agent -console >/dev/null 2>&1 || true

echo "Waiting for Screen Sharing on port 5900..."
for _ in {1..30}; do
  if nc -z 127.0.0.1 5900; then
    break
  fi
  sleep 2
done

if ! nc -z 127.0.0.1 5900; then
  echo "::error::macOS Screen Sharing did not start on port 5900."
  exit 1
fi

echo "Installing the browser VNC bridge and secure HTTPS tunnel..."
NOVNC_VERSION="1.6.0"
NOVNC_ROOT="$RUNNER_TEMP/noVNC"
VENV_ROOT="$RUNNER_TEMP/novnc-venv"

curl --fail --location --silent --show-error \
  "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" \
  --output "$RUNNER_TEMP/novnc.tar.gz"
mkdir -p "$NOVNC_ROOT"
tar -xzf "$RUNNER_TEMP/novnc.tar.gz" --strip-components=1 -C "$NOVNC_ROOT"

python3 -m venv "$VENV_ROOT"
"$VENV_ROOT/bin/python" -m pip install --quiet --disable-pip-version-check websockify==0.13.0

if ! command -v cloudflared >/dev/null 2>&1; then
  brew install cloudflared
fi

nohup "$VENV_ROOT/bin/websockify" \
  --web "$NOVNC_ROOT" \
  6080 127.0.0.1:5900 \
  >"$RUNNER_TEMP/websockify.log" 2>&1 &
echo "$!" > "$RUNNER_TEMP/websockify.pid"

for _ in {1..20}; do
  if nc -z 127.0.0.1 6080; then
    break
  fi
  sleep 1
done

if ! nc -z 127.0.0.1 6080; then
  cat "$RUNNER_TEMP/websockify.log"
  echo "::error::The browser VNC bridge did not start on port 6080."
  exit 1
fi

nohup cloudflared tunnel \
  --url http://127.0.0.1:6080 \
  --no-autoupdate \
  --logfile "$RUNNER_TEMP/cloudflared.log" \
  >"$RUNNER_TEMP/cloudflared.stdout.log" 2>&1 &
echo "$!" > "$RUNNER_TEMP/cloudflared.pid"

TUNNEL_URL=""
for _ in {1..60}; do
  TUNNEL_URL="$(grep -Eho 'https://[-a-z0-9]+\.trycloudflare\.com' \
    "$RUNNER_TEMP/cloudflared.log" \
    "$RUNNER_TEMP/cloudflared.stdout.log" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$TUNNEL_URL" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$TUNNEL_URL" ]]; then
  cat "$RUNNER_TEMP/cloudflared.log" 2>/dev/null || true
  cat "$RUNNER_TEMP/cloudflared.stdout.log" 2>/dev/null || true
  echo "::error::Cloudflare did not provide a temporary HTTPS address."
  exit 1
fi

DESKTOP_URL="${TUNNEL_URL}/vnc.html?autoconnect=1&resize=scale&reconnect=1&show_dot=1"
echo "desktop_url=$DESKTOP_URL" >> "$GITHUB_OUTPUT"

{
  echo "## سطح مكتب macOS جاهز"
  echo
  echo "[افتح Xcode وmacOS من المتصفح]($DESKTOP_URL)"
  echo
  echo "- عند ظهور نافذة كلمة المرور، استخدم كلمة المرور التي تم إعدادها لك."
  echo "- احفظ تعديلاتك بـ Commit وPush قبل إنهاء المهمة؛ الجهاز مؤقت."
  echo "- لإيقاف التكلفة فورًا، اضغط **Cancel workflow** عند الانتهاء."
} >> "$GITHUB_STEP_SUMMARY"

echo "::notice title=Remote macOS Desktop::$DESKTOP_URL"

echo "Opening Xcode and the iPhone Simulator..."
open AnimeShelf.xcodeproj

DEVICE_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
preferred = []
fallback = []
for runtime_devices in data.get("devices", {}).values():
    for device in runtime_devices:
        if not device.get("isAvailable") or not device.get("name", "").startswith("iPhone"):
            continue
        fallback.append(device["udid"])
        if "Pro" in device.get("name", ""):
            preferred.append(device["udid"])
print((preferred or fallback or [""])[0])
')"

if [[ -n "$DEVICE_UDID" ]]; then
  xcrun simctl boot "$DEVICE_UDID" >/dev/null 2>&1 || true
  open -a Simulator --args -CurrentDeviceUDID "$DEVICE_UDID" || true
else
  open -a Simulator || true
fi
