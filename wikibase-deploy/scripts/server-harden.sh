#!/usr/bin/env bash
# Additive hardening only (does not weaken anything): fail2ban for SSH,
# unattended security upgrades, nightly backup cron. Idempotent.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq fail2ban unattended-upgrades >/dev/null

cat > /etc/fail2ban/jail.d/sshd-local.conf <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

cat > /etc/cron.d/mute-wikibase-backup <<'EOF'
# nightly backup at 02:30, keep 7 sets (see scripts/backup.sh)
30 2 * * * root /opt/mute-wikibase/scripts/backup.sh >> /var/log/mute-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/mute-wikibase-backup

echo "== status"
systemctl is-active fail2ban unattended-upgrades
fail2ban-client status sshd | sed -n 1,8p
grep -E '^\s*(PermitRootLogin|PasswordAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || echo "sshd: no explicit overrides (distro defaults)"
sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication) '
