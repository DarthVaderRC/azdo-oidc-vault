#!/bin/bash
set -e

VAULT_VERSION="${VAULT_VERSION:-1.15.0}"
VAULT_ZIP="vault_${VAULT_VERSION}_linux_amd64.zip"
VAULT_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/${VAULT_ZIP}"

echo "=========================================="
echo "Installing Vault CLI v${VAULT_VERSION}"
echo "=========================================="

# Check if already installed
if command -v vault &> /dev/null; then
    INSTALLED_VERSION=$(vault version | head -1 | awk '{print $2}' | sed 's/v//')
    if [ "${INSTALLED_VERSION}" = "${VAULT_VERSION}" ]; then
        echo "Vault ${VAULT_VERSION} is already installed"
        exit 0
    fi
fi

# Download and install
echo "Downloading Vault from ${VAULT_URL}..."
curl -Lo vault.zip "${VAULT_URL}"

echo "Installing Vault..."
unzip -o vault.zip
sudo mv vault /usr/local/bin/
rm vault.zip

# Verify installation
echo ""
echo "Vault installed successfully:"
vault version

echo "=========================================="
