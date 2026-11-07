#!/bin/bash
set -euxo pipefail

dnf install -y httpd php php-fpm php-mysqlnd mariadb105 git
git clone ${repo_url} /opt/app

# --- DB credentials: password pulled from SSM Parameter Store at boot ---
DB_PASS=$(aws ssm get-parameter --name ${db_pass_ssm} --with-decryption \
  --query Parameter.Value --output text --region ${region})

mkdir -p /etc/app
cat > /etc/app/db.ini <<EOF
host = "${db_host}"
user = "${db_user}"
pass = "$DB_PASS"
name = "${db_name}"
EOF
chown root:apache /etc/app/db.ini
chmod 640 /etc/app/db.ini

# --- Deploy API ---
mkdir -p /var/www/html/api
cp -r /opt/app/backend/api/* /var/www/html/api/

# db_connection.php reads credentials from /etc/app/db.ini (nothing hard-coded in Git)
cat > /var/www/html/api/db_connection.php <<'EOF'
<?php
$cfg  = parse_ini_file('/etc/app/db.ini');
$conn = new mysqli($cfg['host'], $cfg['user'], $cfg['pass'], $cfg['name']);
if ($conn->connect_error) {
    http_response_code(500);
    die(json_encode(['error' => 'Database connection failed']));
}
EOF

echo '<?php http_response_code(200); echo "ok";' > /var/www/html/health.php

# --- Initialise schema (safe to re-run if the SQL uses IF NOT EXISTS) ---
mysql -h ${db_host} -u ${db_user} -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS ${db_name};" || true
mysql -h ${db_host} -u ${db_user} -p"$DB_PASS" ${db_name} < /opt/app/database/database_setup.sql || true

systemctl enable --now php-fpm httpd
