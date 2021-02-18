#!/usr/bin/env bash

export DEBIAN_FRONTEND=noninteractive

# Exit the script and an error is encountered
set -o errexit
# Exit the script when a pipe operation fails
set -o pipefail
# Exit the script when there are undeclared variables
set -o nounset

if ! ls /var/log/install-*.log > /dev/null 2>&1; then
  >&2 echo "Platform configuration log file not present - unable to proceed"
  exit 1
fi

# In can take potentially a long time for the VM to finish initializing,
# so we wait for it here before proceeding.
for i in {1..20}; do
  if grep --quiet 'Platform configuration complete' /var/log/install-*.log; then
    break
  else
    >&2 echo "Platform configuration not completed sleeping for 30 seconds"
    sleep 30
  fi
done

if ! grep --quiet 'Platform configuration complete' /var/log/install-*.log; then
  >&2 echo "Platform configuration not completed unable to proceed"
  exit 1
fi

# The temporary folder for this script is set to the physical local disk
export TMPDIR="/mnt/tmp"

# Here we load in the secrets to be used in the installation. This file
# is deleted when this script exits.
source /tmp/secrets.env

# Path to the Let's Encrypt certificates
export CERT_DIR="/etc/letsencrypt/live/${CTR_FQDN}"
export CTR_TSDB_VOL_TYPE="local"

# Use these settings if we are using Azure's PostgreSQL service
if [ "${PG_INSTALL_TYPE}" == "sass" ]; then
  export PGSSLROOTCERT="/etc/ssl/certs/Baltimore_CyberTrust_Root.pem"
  export CTR_DB_PORT="5432"
  export CTR_DB_CA="/etc/ssl/certs/Baltimore_CyberTrust_Root.pem"
  export CTR_DB_ENABLE_SSL="false"
fi

# Path in which to copy the Let's Encrypt certificates to in order for
# them to be able to be read by the Controller installer. This path
# is deleted which this script exits.
LOCAL_CERT_DIR="$(mktemp -t --directory "letsencrypt_certs-XXXXXX")"
# Path to extract installer to
EXTRACT_DIR="$(mktemp -t --directory "nginx-controller-install-XXXXXX")"

finish() {
  result=$?

  if [ $result -ne 0 ]; then
    >&2 echo  "install error: Unable to auto-install NGINX Controller."
  fi

  >&2 echo "Cleaning up secrets file /tmp/secrets.env"
  rm --verbose --force /tmp/secrets.env || true
  >&2 echo "Cleaning up installer files in ${EXTRACT_DIR}"
  rm --verbose --recursive --force "${EXTRACT_DIR}"
  >&2 echo "Cleaning up certificate files in ${LOCAL_CERT_DIR}"
  rm --verbose --recursive --force "${LOCAL_CERT_DIR}"

  exit ${result}
}
trap finish EXIT ERR SIGTERM SIGINT

echo "Copying Let's Encrypt certificates to location where Controller installer can read them"
sudo cp --dereference "${CERT_DIR}/fullchain.pem" "${LOCAL_CERT_DIR}/fullchain.pem"
sudo cp --dereference "${CERT_DIR}/privkey.pem" "${LOCAL_CERT_DIR}/privkey.pem"
CURRENT_USER="$(whoami)"
sudo chown --recursive "${CURRENT_USER}:${CURRENT_USER}" "${LOCAL_CERT_DIR}"

# Set certificate paths to newly created directory
export CTR_APIGW_CERT="${LOCAL_CERT_DIR}/fullchain.pem"
export CTR_APIGW_KEY="${LOCAL_CERT_DIR}/privkey.pem"

# Validate that the required files made it to their destination
if [ ! -f "${CTR_APIGW_CERT}" ]; then
  >&2 echo "Let's encrypt certificate wasn't copied successfully"
  exit 3
fi
if [ ! -f "${CTR_APIGW_KEY}" ]; then
  >&2 echo "Let's encrypt key wasn't copied successfully"
  exit 3
fi

# Add certificate update helper script that can be run from certbot renewal process
if [ ! -f /usr/local/bin/update_controller_certs ]; then
  echo "Adding certificate update script"
  cat > "/tmp/update_controller_certs" << EOF
#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

mkdir /var/tmp/nginx-controller-certs

finish() {
  result=\$?
  rm --recursive --force /var/tmp/nginx-controller-certs
  exit \${result}
}
trap finish EXIT ERR SIGTERM SIGINT

chown $(whoami) /var/tmp/nginx-controller-certs
chmod og-rwx /var/tmp/nginx-controller-certs
cp ${CERT_DIR}/cert.pem /var/tmp/nginx-controller-certs/fullchain.pem
cp ${CERT_DIR}/privkey.pem /var/tmp/nginx-controller-certs/privkey.pem
chown -R $(whoami) /var/tmp/nginx-controller-certs
chmod -R og-rwx /var/tmp/nginx-controller-certs

su --login --command '/opt/nginx-controller/helper.sh configtls /var/tmp/nginx-controller-certs/fullchain.pem /var/tmp/nginx-controller-certs/privkey.pem' $(whoami)
EOF
  sudo mv "/tmp/update_controller_certs" /usr/local/bin/update_controller_certs
  sudo chmod 0770 /usr/local/bin/update_controller_certs
  sudo chown root:root /usr/local/bin/update_controller_certs
fi

# Add post-hook to update Controller certs to certbot cron job
if ! grep --quiet 'deploy-hook' /etc/letsencrypt/cli.ini; then
  echo "Adding deploy hook to certbot configuration"
  printf "\ndeploy-hook = /usr/local/bin/update_controller_certs" | sudo tee --append /etc/letsencrypt/cli.ini > /dev/null
fi

echo 'Extracting NGINX Controller installer'
tar --extract --gunzip --directory="${EXTRACT_DIR}" --strip-components=1 \
  --file "/tmp/controller-installer.tar.gz"

echo 'Installing base prerequisites'
"${EXTRACT_DIR}/helper.sh" prereqs base

if ! command -v docker; then
  echo 'Installing Docker'
  "${EXTRACT_DIR}/helper.sh" prereqs docker
  sudo systemctl stop docker
  sudo systemctl stop containerd
  # Append ephemeral disk location for storing Docker image data
  sudo cp --archive /etc/docker/daemon.json /etc/docker/daemon.json.orig
  REWRITTEN_DAEMON_JSON="$(mktemp -t tmp.daemon.json.XXXXXXX)"
  jq '. + {"data-root": "/mnt/docker-data"}' < /etc/docker/daemon.json > "${REWRITTEN_DAEMON_JSON}"
  sudo cp "${REWRITTEN_DAEMON_JSON}" /etc/docker/daemon.json
  rm "${REWRITTEN_DAEMON_JSON}"
  # Add path to ephemeral disk location for storing containerd data
  sudo cp --archive /etc/containerd/config.toml /etc/containerd/config.toml.orig
  sudo sed -i 's|^\s*#root\s\+=\s\+".*"\s*|root = "/mnt/var/lib/containerd"|' /etc/containerd/config.toml

  sudo systemctl start docker
  sudo systemctl start containerd
fi


if ! command -v kubelet; then
  echo 'Installing Kubernetes'
  # Link location in /opt to default kubelet data directory so that data is installed there by default
  sudo mkdir --parents /opt/var/lib/kubelet
  sudo chmod 0700 /opt/var/lib/kubelet

  if [ ! -h /var/lib/kubelet ]; then
    sudo ln --symbolic /opt/var/lib/kubelet /var/lib/kubelet
  fi

  "${EXTRACT_DIR}/helper.sh" prereqs k8s || >&2 echo 'k8s install script returned a non-zero exit code - ignoring';

  # Update configuration to use larger data disk location for storing kubelet ephemeral data
  if ! sudo stat --terse /etc/default/kubelet > /dev/null 2>&1; then
    echo 'KUBELET_EXTRA_ARGS=--root-dir=/opt/var/lib/kubelet' | sudo tee /etc/default/kubelet > /dev/null
  elif ! sudo grep --quiet '\-\-root-dir' /etc/default/kubelet; then
    echo 'KUBELET_EXTRA_ARGS=--root-dir=/opt/var/lib/kubelet' | sudo tee --append /etc/default/kubelet > /dev/null
  fi

  sudo systemctl stop kubelet
fi

# Test to see if we can connect to Azure's PostgreSQL service
if [ "${PG_INSTALL_TYPE+x}" == "sass" ]; then
  echo 'Waiting for PostgreSQL database to become available'
  wait-for-it --timeout=300 "${CTR_DB_HOST}:${CTR_DB_PORT}"
  echo 'Testing connection to PostgreSQL database'
  PG_TEST_CONN="host=${CTR_DB_HOST} port=${CTR_DB_PORT} dbname=template1 user=${CTR_DB_USER} password=${CTR_DB_PASS} sslmode=verify-full"
  psql "${PG_TEST_CONN}" -c "SELECT 'Hello PostgreSQL';" > /dev/null
fi

"${EXTRACT_DIR}/install.sh" --accept-license --non-interactive

# There is a bug with the Controller installer where if you specify CTR_DB_ENABLE_SSL=true, it will always prompt
# you for a CA file path. We get around by installing with CTR_DB_ENABLE_SSL=false and then switching modes
# post-install.
if [ "${PG_INSTALL_TYPE+x}" == "sass" ]; then
  export CTR_DB_ENABLE_SSL="true"
  "${EXTRACT_DIR}/helper.sh" configdb
fi