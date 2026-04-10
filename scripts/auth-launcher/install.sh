#!/usr/bin/env bash
set -euo pipefail

# Install codex-web-auth management scripts and systemd user service.
# Requires: node >= 18, codexui (npm link or global install), python3

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SHARE_DIR="$HOME/.local/share/codex-auth-launcher"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
NODE_BIN_DIR="$(dirname "$(which node 2>/dev/null || echo /usr/bin/node)")"

echo "Installing codex-web-auth..."

mkdir -p "$SHARE_DIR" "$BIN_DIR" "$SYSTEMD_DIR"

cp -f "$SCRIPT_DIR/manage-codex-web.sh" "$SHARE_DIR/"
cp -f "$SCRIPT_DIR/sync-auth.sh" "$SHARE_DIR/"
chmod +x "$SHARE_DIR/manage-codex-web.sh" "$SHARE_DIR/sync-auth.sh"

cat > "$BIN_DIR/codex-web-auth" <<ENTRY
#!/usr/bin/env bash
set -euo pipefail
exec "$SHARE_DIR/manage-codex-web.sh" "\$@"
ENTRY
chmod +x "$BIN_DIR/codex-web-auth"

cat > "$SYSTEMD_DIR/codex-web-auth.service" <<SERVICE
[Unit]
Description=Codex Web Auth - Multi-profile codexUI launcher
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=$NODE_BIN_DIR:$BIN_DIR:/usr/local/bin:/usr/bin:/bin
ExecStart=$BIN_DIR/codex-web-auth start-folder
ExecStop=$BIN_DIR/codex-web-auth stop-folder
ExecReload=$BIN_DIR/codex-web-auth restart-folder
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable codex-web-auth.service 2>/dev/null || true

echo ""
echo "Installed:"
echo "  Scripts:  $SHARE_DIR/"
echo "  Command:  $BIN_DIR/codex-web-auth"
echo "  Service:  $SYSTEMD_DIR/codex-web-auth.service (enabled)"
echo ""
echo "Usage:"
echo "  codex-web-auth start-folder [profiles-dir]    # Start all profiles (default: ~/.codex-auth-launcher/profiles)"
echo "  codex-web-auth stop-folder  [profiles-dir]    # Stop all"
echo "  codex-web-auth status-folder [profiles-dir]   # Status of all"
echo "  codex-web-auth sync-folder  [profiles-dir]    # Sync auth for all"
echo "  codex-web-auth list                           # List all services"
echo "  codex-web-auth logs <service-name>            # Show logs"
echo ""
echo "Systemd:"
echo "  systemctl --user start codex-web-auth   # Start now"
echo "  systemctl --user stop codex-web-auth    # Stop now"
echo "  systemctl --user status codex-web-auth  # Check status"
echo "  journalctl --user -u codex-web-auth     # View journal logs"
echo ""
echo "Ports are auto-assigned starting from 8051."
