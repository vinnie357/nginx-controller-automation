#!/usr/bin/env bash

# This script installs Pulumi, Python, Python dependencies, and the Azure CLI.

# Exit the script and an error is encountered
set -o errexit
# Exit the script when a pipe operation fails
set -o pipefail
# Exit the script when there are undeclared variables
set -o nounset

if [ -n "${NONINTERACTIVE-}" ]; then
  export DEBIAN_FRONTEND=noninteractive
  assume_yes="-y"
else
  assume_yes=""
fi

# Detect if we are currently a user with root level permissions and if
# the sudo command is available
sudo_cmd=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo > /dev/null; then
    sudo_cmd="sudo"
  else
    sudo_cmd="invalid"
  fi
fi

# Flag indicating if the package repository cache has been updated
# This is only relevant for debian-like distros
packages_updated=0

# Set the required packages based on OS and Linux distro
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  if grep 'ID_LIKE=debian\|ID=debian' /etc/os-release > /dev/null 2>&1; then
    pkg_manager="apt-get"
    python3_pkg="python3"
    python3_venv_pkg="python3-venv"
    python3_dev_pkg="python3-dev"
    gpp_pkg="g++"
    rustc_pkg="rustc"
    libssl_dev="libssl-dev"
  elif grep 'ID_LIKE=.*rhel.*\|ID=fedora' /etc/os-release > /dev/null 2>&1; then
    pkg_manager="yum"
    python3_pkg="python3"
    python3_venv_pkg=""
    python3_dev_pkg="python3-devel"
    gpp_pkg="gcc-c++"
    rustc_pkg="rust cargo"
    libssl_dev="openssl-devel"
  else
    >&2 echo 'unsupported Linux distribution'
    exit 1
  fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
  if ! command -v brew > /dev/null; then
    >&2 echo 'homebrew not installed - install homebrew and retry'
    exit 1
  fi
  pkg_manager="brew"
  sudo_cmd="" # if we are using homebrew, we don't use sudo to install packages
  assume_yes="" # homebrew doesn't take an assume parameter
  python3_pkg="python@3"
  python3_venv_pkg=""
  python3_dev_pkg=""
  gpp_pkg="gcc"
  rustc_pkg="rust"
  libssl_dev="openssl"
else
  >&2 echo 'unsupported OS'
  exit 1
fi

resolve_path() {
  if command -v realpath > /dev/null; then
    realpath --logical "$1"
  else
    python3 -c "import os; print(os.path.realpath('$1'));"
  fi
}

function update_packages() {
  if [ "${sudo_cmd}" == "invalid" ]; then
    >&2 echo 'unable to update packages - insufficient access'
    exit 1
  fi

  if [ ${packages_updated} -ne 0 ]; then
    return 0
  fi

  if ! command -v ${pkg_manager} > /dev/null; then
    >&2 echo "${pkg_manager} not in path - unable to continue"
    exit 1
  fi

  if [ "${pkg_manager}" == "apt-get" ]; then
    ${sudo_cmd} apt-get update
  fi

  packages_updated=1
}

function install_packages() {
  if [ "${sudo_cmd}" == "invalid" ]; then
    >&2 echo 'unable to install packages - insufficient access'
    exit 1
  fi

  update_packages
  ${sudo_cmd} ${pkg_manager} install "${assume_yes}" "$@"
}

function install_azure_cli() {
if [ "${pkg_manager}" == "brew" ]; then
  install_packages azure-cli
elif [ "${pkg_manager}" == "apt-get" ]; then
  curl -sL https://aka.ms/InstallAzureCLIDeb | ${sudo_cmd} bash
elif [ "${pkg_manager}" == "yum" ]; then
  ${sudo_cmd} rpm --import https://packages.microsoft.com/keys/microsoft.asc
  echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" | ${sudo_cmd} tee /etc/yum.repos.d/azure-cli.repo > /dev/null
  ${sudo_cmd} yum install "${assume_yes}" azure-cli
fi
}

>&2 echo 'checking if Python 3 is installed'
if ! command -v python3 > /dev/null; then
  install_packages ${python3_pkg}
fi

>&2 echo 'checking if at least Python 3.6 is installed'
if [ 6 -gt "$(python3 --version | cut -f2 -d' ' | cut -f2 -d '.')" ]; then
  >&2 echo "at least python 3.6+ is required for this project"
  exit 1
fi


>&2 echo 'checking if Python venv module is installed'
if ! python3 -c "import sys, pkgutil; sys.exit(0 if pkgutil.find_loader(sys.argv[1]) else 1)" venv; then
  install_packages ${python3_venv_pkg}
elif [ "${pkg_manager}" == "apt-get" ] && ! dpkg -s python3-venv > /dev/null 2>&1; then
  install_packages ${python3_venv_pkg}
fi

# Directory in which script is running
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
# Establish the project directory relative to the current script's path
project_dir="$(resolve_path "${script_dir}/..")"

>&2 echo "checking if venv environment is present in the current project: ${project_dir}"
if [ ! -d "${project_dir}/venv" ]; then
  >&2 echo "creating venv environment: ${project_dir}/venv"
  python3 -m venv "${project_dir}/venv"
fi

source "${project_dir}/venv/bin/activate"

if ! command -v pip3 > /dev/null; then
  >&2 echo "pip3 is not in path: $PATH"
  exit 1
fi

# Make sure that the venv environment has the latest pip
pip3 install --upgrade pip

# Installing wheel so that we can install required modules using packages
pip3 install wheel

# Try install dependencies without building, if this fails we will add
# build dependencies
if ! pip3 install -r "${project_dir}/requirements.txt"; then
  >&2 echo 'unable to install Python requirements with wheels - trying to add additional build dependencies'

  packages_to_install=""

  >&2 echo 'check if Python development libraries are installed'
  if ! echo '#include <Python.h>' | cpp -H -o /dev/null > /dev/null 2>&1; then
    packages_to_install="${packages_to_install} ${python3_dev_pkg}"
  fi

  >&2 echo 'checking for c++ compiler'
  if ! command -v c++ > /dev/null; then
    packages_to_install="${packages_to_install} ${gpp_pkg}"
  fi

  >&2 echo 'checking for rust compiler'
  if ! command -v rustc > /dev/null || ! command -v cargo > /dev/null; then
    packages_to_install="${packages_to_install} ${rustc_pkg}"
  fi

  >&2 echo 'check if openssl development libraries are installed'
  if ! echo '#include <openssl/opensslv.h>' | cpp -H -o /dev/null > /dev/null 2>&1; then
    packages_to_install="${packages_to_install} ${libssl_dev}"
  fi

  if [ "${packages_to_install}" != "" ]; then
    # shellcheck disable=SC2086
    install_packages ${packages_to_install}
  fi

  pip3 install setuptools_rust
  pip3 install -r "${project_dir}/requirements.txt"
fi

>&2 echo 'checking if Pulumi is installed'
if ! command -v pulumi > /dev/null; then
  if [ -f "${HOME}/.pulumi/bin/pulumi" ]; then
    >&2 echo "Pulumi found but not in path - using [${HOME}/.pulumi/bin/pulumi] - consider adding this directory to your runtime path"
    export PATH=$PATH:$HOME/.pulumi/bin
  elif [ "${pkg_manager}" == "brew" ]; then
    # If we have homebrew, then we can quickly install pulumi using it
    install_packages pulumi
  else
    if ! command -v curl > /dev/null; then
      install_packages curl
    fi

    curl -fsSL https://get.pulumi.com | sh
    export PATH=$PATH:$HOME/.pulumi/bin
  fi
fi

install_azure_cli