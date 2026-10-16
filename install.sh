#!/bin/bash
# استقرار بات تلگرام + سرور OpenCode بدون داکر (روی خود هاست، با root اجرا شود)
set -eu

CONTAINER="${1:-$(docker ps --format '{{.Names}}' | head -1)}"
if [ -z "$CONTAINER" ]; then echo "no running container found; pass container name as \$1"; exit 1; fi
echo "==> source container: $CONTAINER"

# 1) Node 22
if ! command -v node >/dev/null || ! node --version | grep -Eq 'v(2[2-9]|[3-9][0-9])'; then
  echo "==> installing Node 22"
  apt-get update && apt-get install -y ca-certificates curl gnupg
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt-get update && apt-get install -y nodejs
fi
node --version

# 2) فایل‌ها از کانتینر (نسخه دقیقِ در حال اجرا)
mkdir -p /opt/bot/app /opt/bot/data /opt/bot/tmp
echo "==> copying app (dist, deps, configs)"
docker cp "$CONTAINER:/app/dist" /opt/bot/app/dist
docker cp "$CONTAINER:/app/package.json" /opt/bot/app/package.json
docker cp "$CONTAINER:/app/opencode.json" /opt/bot/app/opencode.json
docker cp "$CONTAINER:/app/node_modules" /opt/bot/app/node_modules
echo "==> copying opencode v2 binaries (exact version)"
docker cp "$CONTAINER:/opt/opencode-v2" /opt/opencode-v2
chmod +x /opt/opencode-v2/bin/opencode
echo "==> copying bot data (sessions, settings, logs)"
docker cp "$CONTAINER:/app/data/." /opt/bot/data/
mkdir -p /root/.config/opencode
docker exec "$CONTAINER" cat /root/.config/opencode/opencode.json > /root/.config/opencode/opencode.json 2>/dev/null || cp /opt/bot/app/opencode.json /root/.config/opencode/opencode.json

# 3) فایل env (توکن‌ها از کانتینر خوانده می‌شود، چیزی لاگ نمی‌شود)
if [ ! -f /opt/bot/.env ]; then
  {
    echo "OPENCODE_SERVER_VERSION=v2"
    echo "OPENCODE_API_URL=http://127.0.0.1:49374"
    echo "OPENCODE_SERVER_USERNAME=opencode"
    printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$(docker exec "$CONTAINER" cat /root/.v2pw)"
    for v in TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USER_ID GH_TOKEN GIT_USER_NAME GIT_USER_EMAIL; do
      val="$(docker exec "$CONTAINER" printenv "$v" 2>/dev/null || true)"
      printf '%s=%s\n' "$v" "$val"
    done
  } > /opt/bot/.env
  chmod 600 /opt/bot/.env
  echo "==> /opt/bot/.env created from container env"
fi

# 4) سرویس‌ها (فرض: فایل‌های .service کنار همین اسکریپت‌اند)
cp opencode-server.service opencode-bot.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now opencode-server.service
echo "==> waiting for opencode server..."
for i in $(seq 1 60); do
  systemctl is-active -q opencode-server.service || { echo "server service died"; systemctl status opencode-server.service --no-pager | tail -5; exit 1; }
  sleep 1
done
systemctl enable --now opencode-bot.service
sleep 8
systemctl is-active -q opencode-bot.service && echo "BOT ACTIVE ✅" || { echo "bot failed"; journalctl -u opencode-bot.service --no-pager | tail -10; exit 1; }
echo "==> check Telegram: bot should answer. THEN stop docker container to free ~15GB:"
echo "    docker stop $CONTAINER && docker rm $CONTAINER && docker system prune -a"
