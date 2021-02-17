#!/usr/bin/env bash

# This script installs Pulumi, Python, Python dependencies,
#

# Exit the script and an error is encountered
set -o errexit
# Exit the script when a pipe operation fails
set -o pipefail
# Exit the script when there are undeclared variables
set -o nounset

>&2 echo 'checking for Pulumi access token - if not found logging into Pulumi'
if [ -z "${PULUMI_ACCESS_TOKEN+x}" ]; then
  pulumi login
fi

if [ -n "${ARM_CLIENT_ID+x}" ] && [ -n "${ARM_CLIENT_SECRET+x}" ] && [ -n "${ARM_TENANT_ID+x}" ] && [ -n "${ARM_SUBSCRIPTION_ID+x}" ]; then
  >&2 echo 'skipping Azure CLI login because ARM environment variables are present'
else
  az login
fi

resolve_path() {
  if command -v realpath > /dev/null; then
    realpath --logical "$1"
  else
    python3 -c "import os; print(os.path.realpath('$1'));"
  fi
}

# Directory in which script is running
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
# Establish the project directory relative to the current script's path
project_dir="$(resolve_path "${script_dir}/..")"

# Set the project directory as part of Pulumi's default execution
pulumi_cmd="pulumi --cwd ${project_dir}"

installer_archive_dir="$(resolve_path "${project_dir}/installer-archives")"
installer_archive_path="$(find "${installer_archive_dir}" -name 'controller-installer-*.tar.gz' -type f | sort --version-sort --reverse | head -n 1)"
if [ "${installer_archive_path}" == "" ]; then
  >&2 echo 'no controller installer archive found'
  exit 1
else
  >&2 echo "selected ${installer_archive_path} as the Controller installer archive"
  >&2 echo "if this is incorrect, run the following command to select a different archive:"
  >&2 echo "pulumi config set nginx-controller:controller_archive_path <archive_path>"
  ${pulumi_cmd} config set nginx-controller:controller_archive_path "${installer_archive_path}"
fi

>&2 echo 'Azure region to deploy to'
${pulumi_cmd} config set azure:location
>&2 echo 'An id that uniquely identifies the Controller installation (defaults to the lowercase stack name). You probably want to set this because there can be resource name conflicts on Azure with the domain name assigned to the VM. This id must be lowercase using only letters or numbers with no additional punctuation.'
${pulumi_cmd} config set nginx-controller:installation_id
>&2 echo "Email address to associate with the administrator of Controller. This value is used by Controller to send password resets as well as by Let's Encrypt as the administrative contact address."
${pulumi_cmd} config set nginx-controller:admin_email
>&2 echo 'The first name of the administrator of Controller'
${pulumi_cmd} config set nginx-controller:admin_first_name
>&2 echo 'The last name of the administrator of Controller'
${pulumi_cmd} config set nginx-controller:admin_last_name
>&2 echo 'The password for the Controller UI'
${pulumi_cmd} config set --secret nginx-controller:admin_password
>&2 echo 'The password for the user created on the Controller VM'
${pulumi_cmd} config set --secret nginx-controller:controller_host_password
>&2 echo 'The user created on the Controller VM'
${pulumi_cmd} config set nginx-controller:controller_host_username
>&2 echo 'Value determines how PostgreSQL is installed:'
>&2 echo " 'local' installs it on the same VM as Controller"
>&2 echo " 'sass' creates a new PostgreSQL instance using Azure's SasS offering"
${pulumi_cmd} config set nginx-controller:db_type

if [ "$(${pulumi_cmd} config get nginx-controller:db_type)" = "sass" ]; then
  >&2 echo 'The admin user created on the new PostgreSQL instance'
  ${pulumi_cmd} set nginx-controller:db_admin_password
fi

>&2 echo "Boolean flag indicating if the SMTP server requires authentication - must be lowercase string 'true' or 'false'"
${pulumi_cmd} set nginx-controller:smtp_auth
>&2 echo 'From address for Controller to send emails from'
${pulumi_cmd} config set nginx-controller:smtp_from
>&2 echo 'SMTP hostname'
${pulumi_cmd} config set nginx-controller:smtp_host
>&2 echo 'SMTP port number'
${pulumi_cmd} config set nginx-controller:smtp_port

if [ "$(${pulumi_cmd} config get nginx-controller:smtp_auth)" == "true" ]; then
  >&2 echo 'SMTP username'
  ${pulumi_cmd} config set nginx-controller:smtp_user
  >&2 echo 'SMTP password'
  ${pulumi_cmd} config set --secret nginx-controller:smtp_pass
fi

>&2 echo "Boolean flag indicating if TLS is required with SMTP - must be lowercase string 'true' or 'false'"
${pulumi_cmd} config set nginx-controller:smtp_tls