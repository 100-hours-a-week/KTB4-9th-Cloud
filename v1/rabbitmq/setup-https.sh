#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
domain="rabbitmq.cosmoscode.site"
site_available="/etc/nginx/sites-available/${domain}"
site_enabled="/etc/nginx/sites-enabled/${domain}"
certificate="/etc/letsencrypt/live/${domain}/fullchain.pem"

if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx
fi

if ! sudo test -f "${certificate}"; then
  sudo install -m 644 "${script_dir}/nginx-rabbitmq-bootstrap.conf" "${site_available}"
  sudo ln -sfn "${site_available}" "${site_enabled}"
  sudo nginx -t
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx

  sudo certbot certonly --nginx \
    --domain "${domain}" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email
fi

sudo install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
printf '#!/usr/bin/env bash\nset -e\nsystemctl reload nginx\n' |
  sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

sudo install -m 644 "${script_dir}/nginx-rabbitmq.conf" "${site_available}"
sudo ln -sfn "${site_available}" "${site_enabled}"
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx

printf 'RabbitMQ management UI is available at https://%s\n' "${domain}"
