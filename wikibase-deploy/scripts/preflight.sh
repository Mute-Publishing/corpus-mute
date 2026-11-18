#!/usr/bin/env bash
# READ-ONLY pre-flight inventory of the target server. Changes nothing.
# Usage: ssh -i ~/.ssh/id_wikibase_sync root@<ip> 'bash -s' < scripts/preflight.sh
set -u
echo "== host"; hostname; . /etc/os-release; echo "$PRETTY_NAME"; uname -r
echo "== resources"; nproc; free -m | sed -n 1,3p; df -h / | tail -1; swapon --show
echo "== docker"; docker --version 2>&1; docker compose version 2>&1
echo "== containers"; docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1
echo "== volumes"; docker volume ls --format '{{.Name}}' 2>&1
echo "== networks"; docker network ls --format '{{.Name}}' 2>&1 | grep -v -E '^(bridge|host|none)$'
echo "== listening 22/80/443/8080/8081/9999"; ss -tlnp 2>/dev/null | grep -E ':(22|80|443|8080|8081|9999)\b'
echo "== nginx/certbot"; systemctl is-active nginx 2>&1; systemctl is-enabled nginx 2>&1; ls /etc/nginx/sites-enabled 2>&1; ls /etc/letsencrypt/live 2>&1
echo "== repos/dirs"; ls -la /opt 2>&1; ls /opt/wikibase 2>&1 | head -40
echo "== firewall"; (ufw status verbose 2>&1 | head -20); systemctl is-active fail2ban 2>&1
echo "== ssh hardening"; grep -E '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null
echo "== cron"; crontab -l 2>&1 | head -20; ls /etc/cron.d 2>&1
echo "== users"; getent passwd | awk -F: '$3>=1000 && $3<65000 {print $1}'
