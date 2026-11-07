#!/bin/bash
set -euxo pipefail

dnf install -y nginx git
git clone ${repo_url} /opt/app

rm -rf /usr/share/nginx/html/*
cp -r /opt/app/frontend/* /usr/share/nginx/html/

cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 1024; }

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  server {
    listen 80 default_server;
    root /usr/share/nginx/html;
    index index.html;

    location = /health {
      access_log off;
      return 200 'ok';
    }

    # API calls are forwarded to the internal ALB (app tier)
    location /api/ {
      proxy_pass http://${app_alb_dns};
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
    }
  }
}
EOF

systemctl enable --now nginx
