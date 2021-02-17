#!/usr/bin/env bash

# This script is for testing purposes. It runs the the base_setup.sh script on
# a few different Linux distributions using Docker and will return an error if
# the script fails.

# Exit the script and an error is encountered
set -o errexit
# Exit the script when a pipe operation fails
set -o pipefail
# Exit the script when there are undeclared variables
set -o nounset

# Directory in which script is running
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
mount_dir="$(realpath --logical "${script_dir}/..")"

declare -a distros=("debian" "ubuntu" "centos" "fedora")

for distro in "${distros[@]}"; do
  >&2 echo "###############################################"
  >&2 echo "## Testing on ${distro}"
  >&2 echo "###############################################"
  docker run -t --rm -e NONINTERACTIVE=1 -e PULUMI_ACCESS_TOKEN="xxxx" -v "${mount_dir}:/mnt" "${distro}" /bin/bash -ec "
mkdir -p /tmp/azure-pulumi; \
cp -r /mnt/setup /tmp/azure-pulumi/; \
cp /mnt/Pulumi.yaml /tmp/azure-pulumi/; \
cp /mnt/requirements.txt /tmp/azure-pulumi/; \
cd /tmp/azure-pulumi; \
source setup/base_setup.sh"
done
