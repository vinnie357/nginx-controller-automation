#!/usr/bin/env bash

# Open STDOUT as $LOG_FILE file for read and write.
LOGFILE="/var/log/install-$(date +%s).log"
sudo touch "${LOGFILE}"
sudo chown "$(whoami)" "${LOGFILE}"
exec 1<>"${LOGFILE}"

# Redirect STDERR to STDOUT
exec 2>&1

export DEBIAN_FRONTEND=noninteractive

# Exit the script and an error is encountered
set -o errexit
# Exit the script when a pipe operation fails
set -o pipefail
# Exit the script when there are undeclared variables
set -o nounset

export TMPDIR="/mnt/tmp"

TLS_HOSTNAME=""
CERTBOT_FLAGS=""
CERT_DIR="/etc/letsencrypt/live/${TLS_HOSTNAME}"
LETS_ENCRYPT_EMAIL=""

# Install prerequisite dependencies
sudo apt-get update -qq
sudo apt-get install -qq -y \
  apt-transport-https bash ca-certificates certbot conntrack coreutils curl ebtables ethtool gawk gettext \
  gettext-base grep gzip iproute2 iptables jq less libc-bin mount openssl parted postgresql-client procps \
  sed socat software-properties-common sudo tar util-linux wait-for-it xfsprogs

if [ "$(swapon --show)" != "" ]; then
  >&2 echo 'swap detected: In order to install NGINX Controller, swap must be disabled.';
  exit 1
fi

# Setup temporary directories on local storage
sudo mkdir -p "${TMPDIR}"
sudo chmod 1777 "${TMPDIR}"

if [ ! -d /opt ]; then
  sudo mkdir /opt
fi

if ! grep --quiet '/opt' /etc/fstab; then
  DISK_LINK='/dev/disk/azure/scsi1/lun3'

  # Assume we assigned LUN 3 to this disk
  if [ -h /dev/disk/azure/scsi1/lun3 ]; then
    DISK_DEV="$(readlink -f ${DISK_LINK})"
    echo 'Partitioning data disk'
    sudo parted "${DISK_DEV}" --script mklabel gpt mkpart xfspart xfs 0% 100%
    sudo mkfs.xfs "${DISK_DEV}1"
    sudo partprobe "${DISK_DEV}1"

    PARTITION_UUID="$(sudo blkid | grep "${DISK_DEV}1" | cut --fields=2 --delimiter=' ' | cut --fields=2 --delimiter='=' | tr -d '"')"
    sudo echo "# NGINX Controller drive mount" | sudo tee --append /etc/fstab > /dev/null
    sudo echo "UUID=${PARTITION_UUID}   /opt   xfs   defaults,discard,noatime,nofail   1   2"  | \
      sudo tee --append /etc/fstab > /dev/null
    sudo mount /opt
  else
    >&2 echo "Unable to find data disk to partition - installing to base disk"
  fi
fi

# Add the default PostgreSQL CA
if ! grep --quiet 'PGSSLROOTCERT' /etc/environment; then
  sudo echo 'PGSSLROOTCERT="/etc/ssl/certs/Baltimore_CyberTrust_Root.pem"' | sudo tee --append /etc/environment > /dev/null
fi

if ! sudo stat --terse "${CERT_DIR}/fullchain.pem" > /dev/null 2>&1; then
  echo "Generating certificates with Let's Encrypt"
  sudo certbot certonly --standalone \
       -m "${LETS_ENCRYPT_EMAIL}" \
       ${CERTBOT_FLAGS} \
       --agree-tos --force-renewal --non-interactive \
       -d "${TLS_HOSTNAME}"
fi

echo "Platform configuration complete"