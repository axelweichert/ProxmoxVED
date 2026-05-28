#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Fabian Pulch (fpulch)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/paperclipai/paperclip
#
# PATCHED VERSION
# Changes vs upstream:
#   1. fetch_and_deploy_gh_release is called with app name "paperclip" (not
#      "paperclip-ai") so it extracts into /opt/paperclip, matching everything
#      else in this script.
#   2. System PostgreSQL 17 setup REMOVED. Paperclip uses its own embedded
#      PostgreSQL (@embedded-postgres/linux-x64) and never connects to the
#      system instance. The system Postgres was dead weight and never used.
#   3. DATABASE_URL line removed from .env — Paperclip manages its own DB
#      under $PAPERCLIP_HOME/instances/default/db.
#   4. Ensure the "postgres" system user exists before running migrations,
#      since embedded-postgres' initdb requires it to drop privileges.
#   5. PAPERCLIP_HOME owned by postgres so initdb can write into it.

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  git \
  python3 \
  ripgrep \
  passwd
msg_ok "Installed Dependencies"

NODE_VERSION="24" NODE_MODULE="pnpm" setup_nodejs

msg_info "Creating postgres system user (for embedded PostgreSQL)"
if ! id postgres >/dev/null 2>&1; then
  $STD adduser --system --group --home /var/lib/postgresql --shell /bin/bash postgres
fi
msg_ok "Created postgres system user"

# NOTE: app name MUST be "paperclip" so target dir becomes /opt/paperclip
fetch_and_deploy_gh_release "paperclip" "paperclipai/paperclip" "tarball"

msg_info "Building Paperclip"
cd /opt/paperclip
export HUSKY=0
export NODE_OPTIONS="--max-old-space-size=8192"
$STD pnpm install --frozen-lockfile
$STD pnpm build
unset NODE_OPTIONS
msg_ok "Built Paperclip"

msg_info "Installing Agent CLIs"
$STD npm install -g \
  @anthropic-ai/claude-code@latest \
  @openai/codex@latest
msg_ok "Installed Agent CLIs"

msg_info "Configuring Paperclip"
mkdir -p /opt/paperclip-data
chown -R postgres:postgres /opt/paperclip-data
chmod 750 /opt/paperclip-data
mkdir -p /root/.claude /root/.codex
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
cat <<EOF >/opt/paperclip/.env
HOST=0.0.0.0
PORT=3100
SERVE_UI=true
PAPERCLIP_HOME=/opt/paperclip-data
PAPERCLIP_INSTANCE_ID=default
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_DEPLOYMENT_EXPOSURE=private
PAPERCLIP_PUBLIC_URL=http://${LOCAL_IP}:3100
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
EOF
msg_ok "Configured Paperclip"

msg_info "Running Database Migrations"
set -a && source /opt/paperclip/.env && set +a
# embedded-postgres needs a writable home for the postgres user
chown -R postgres:postgres /opt/paperclip-data
$STD pnpm db:migrate
msg_ok "Ran Database Migrations"

msg_info "Bootstrapping Paperclip"
PAPERCLIP_ONBOARD_LOG=/opt/paperclip/paperclip-onboard.log
PAPERCLIP_BOOTSTRAP_LOG=/opt/paperclip/paperclip-bootstrap.log

# Idempotency: if a previous run already produced the config, skip onboarding.
if [[ ! -f /opt/paperclip-data/instances/default/config.json ]]; then
  for PAPERCLIP_ONBOARD_CMD in \
    "pnpm paperclipai onboard --yes --bind lan" \
    "pnpm paperclipai onboard --yes"; do
    rm -f "$PAPERCLIP_ONBOARD_LOG"
    setsid bash -c "cd /opt/paperclip && ${PAPERCLIP_ONBOARD_CMD}" >"$PAPERCLIP_ONBOARD_LOG" 2>&1 &
    PAPERCLIP_ONBOARD_PID=$!
    for _ in {1..60}; do
      if [[ -f /opt/paperclip-data/instances/default/config.json ]]; then
        break
      fi
      if ! kill -0 "$PAPERCLIP_ONBOARD_PID" 2>/dev/null; then
        break
      fi
      sleep 2
    done
    if kill -0 "$PAPERCLIP_ONBOARD_PID" 2>/dev/null; then
      kill -- -"${PAPERCLIP_ONBOARD_PID}" >/dev/null 2>&1 || true
      wait "$PAPERCLIP_ONBOARD_PID" 2>/dev/null || true
    fi
    [[ -f /opt/paperclip-data/instances/default/config.json ]] && break
    if ! grep -q "unknown option '--bind'" "$PAPERCLIP_ONBOARD_LOG"; then
      break
    fi
    msg_info "Retrying Paperclip Onboarding"
  done
fi

if [[ ! -f /opt/paperclip-data/instances/default/config.json ]]; then
  msg_error "Failed to bootstrap Paperclip"
  msg_error "Check /opt/paperclip/paperclip-onboard.log for details"
  exit 1
fi

if grep -q 'authenticated' /opt/paperclip-data/instances/default/config.json; then
  pnpm paperclipai auth bootstrap-ceo >"$PAPERCLIP_BOOTSTRAP_LOG" 2>&1 || true
  PAPERCLIP_INVITE_URL=$(awk -F'Invite URL: ' '/Invite URL:/ {print $2; exit}' "$PAPERCLIP_BOOTSTRAP_LOG")
  PAPERCLIP_INVITE_EXPIRY=$(awk -F'Expires: ' '/Expires:/ {print $2; exit}' "$PAPERCLIP_BOOTSTRAP_LOG")
  if [[ -n "$PAPERCLIP_INVITE_URL" ]]; then
    cat <<EOF >>~/paperclip.creds

Paperclip Admin Invite
Invite URL: ${PAPERCLIP_INVITE_URL}
Expires: ${PAPERCLIP_INVITE_EXPIRY}
EOF
    msg_ok "Generated Paperclip CEO Invite"
    echo -e "${INFO}${YW} Open this invite URL to finish Paperclip admin setup:${CL}"
    echo -e "${TAB}${GATEWAY}${BGN}${PAPERCLIP_INVITE_URL}${CL}"
    [[ -n "$PAPERCLIP_INVITE_EXPIRY" ]] && echo -e "${TAB}${INFO}${YW}Invite expires: ${PAPERCLIP_INVITE_EXPIRY}${CL}"
  else
    msg_warn "Paperclip authenticated mode is enabled, but no CEO invite was generated automatically"
  fi
else
  msg_info "Paperclip Bootstrapped in Local Trusted Mode"
fi
rm -f "$PAPERCLIP_ONBOARD_LOG" "$PAPERCLIP_BOOTSTRAP_LOG"
msg_ok "Bootstrapped Paperclip"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/paperclip.service
[Unit]
Description=Paperclip
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/paperclip
EnvironmentFile=/opt/paperclip/.env
Environment=HOME=/root
Environment=CODEX_HOME=/root/.codex
Environment=PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=DISABLE_AUTOUPDATER=1
ExecStart=/usr/bin/env pnpm paperclipai run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now paperclip
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
