#!/bin/bash
set -euo pipefail

APP_DIR="/opt/scalelab"

dnf install -y aws-cli

mkdir -p "$APP_DIR/bin"

cat > "$APP_DIR/refresh-env.sh" <<EOF
#!/bin/bash
set -euo pipefail
DB_URL=\$(aws ssm get-parameter --name "/${project_name}/database_url" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
REPLICA_URL=\$(aws ssm get-parameter --name "/${project_name}/database_replica_url" --with-decryption --query Parameter.Value --output text --region "${aws_region}" 2>/dev/null || true)
REDIS_URL=\$(aws ssm get-parameter --name "/${project_name}/redis_url" --with-decryption --query Parameter.Value --output text --region "${aws_region}" 2>/dev/null || true)
ADMIN_KEY=\$(aws ssm get-parameter --name "/${project_name}/admin_api_key" --with-decryption --query Parameter.Value --output text --region "${aws_region}")
cat > /opt/scalelab/env <<ENV
PORT=${api_port}
DATABASE_URL=\$DB_URL
DATABASE_REPLICA_URL=\$REPLICA_URL
REDIS_URL=\$REDIS_URL
ADMIN_API_KEY=\$ADMIN_KEY
CORS_ORIGINS=${cors_origins}
ENV
EOF
chmod +x "$APP_DIR/refresh-env.sh"

cat > "$APP_DIR/bin/api" <<'PLACEHOLDER'
#!/bin/bash
echo "Waiting for deploy-api.sh to upload the Go binary..." >&2
exit 1
PLACEHOLDER
chmod +x "$APP_DIR/bin/api"

cat > /etc/systemd/system/scalelab-api.service <<EOF
[Unit]
Description=Scale Lab Go API
After=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/scalelab/env
ExecStart=/opt/scalelab/bin/api
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

"$APP_DIR/refresh-env.sh" || true

if [[ -n "${artifacts_bucket}" ]]; then
  for i in 1 2 3 4 5; do
    if aws s3 cp "s3://${artifacts_bucket}/api/scalelab-api" "$APP_DIR/bin/api" --region "${aws_region}"; then
      chmod +x "$APP_DIR/bin/api"
      break
    fi
    sleep 10
  done
fi

systemctl daemon-reload
systemctl enable scalelab-api
systemctl restart scalelab-api || systemctl start scalelab-api || true
