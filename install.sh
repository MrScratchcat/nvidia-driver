#!/bin/bash
#===============================================================================
# lwl nvidia-driver installer (resolute / 595)
#
# Usage:
#   curl -fsSL https://mrscratchcat.github.io/nvidia-driver/install.sh | sudo bash
#
# Or with explicit driver flavour:
#   curl -fsSL https://mrscratchcat.github.io/nvidia-driver/install.sh \
#     | sudo DRIVER_PKG=nvidia-driver-595-open bash
#===============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REPO_OWNER=MrScratchcat
REPO_NAME=nvidia-driver
REPO_TAG=apt-resolute-v1
PAGES_BASE="https://mrscratchcat.github.io/${REPO_NAME}"
RELEASE_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${REPO_TAG}"
DRIVER_PKG=${DRIVER_PKG:-nvidia-driver-595}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root or with sudo${NC}"
    exit 1
fi

echo -e "${GREEN}=== lwl nvidia-driver installer (${DRIVER_PKG}) ===${NC}"

#===============================================================================
# Step 1: Detect NVIDIA GPU
#===============================================================================
echo -e "${YELLOW}[1/7] Detecting NVIDIA GPU...${NC}"

if ! lspci -nnk | grep -q "10de:"; then
    echo -e "${RED}No NVIDIA GPU detected. Aborting.${NC}"
    exit 1
fi
echo "Found: $(lspci -nnk | grep -A2 '10de:' | grep -E 'VGA|3D|Display' | head -1)"

#===============================================================================
# Step 2: Install kernel headers (required for DKMS build)
#===============================================================================
echo -e "${YELLOW}[2/7] Ensuring kernel headers for $(uname -r)...${NC}"

apt-get update -qq
if ! dpkg-query -W -f='${Status}' "linux-headers-$(uname -r)" 2>/dev/null | grep -q "install ok installed"; then
    apt-get install -y "linux-headers-$(uname -r)" || {
        echo -e "${YELLOW}Per-kernel headers not in repos; installing the generic meta-package.${NC}"
        apt-get install -y linux-headers-generic
    }
fi
apt-get install -y dkms build-essential

#===============================================================================
# Step 3: Trust the lwl signing key
#===============================================================================
echo -e "${YELLOW}[3/7] Installing lwl signing key...${NC}"

install -d -m 0755 /etc/apt/keyrings
curl -fsSL "${PAGES_BASE}/keys/nvidia-driver.gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/nvidia-driver.gpg
chmod 0644 /etc/apt/keyrings/nvidia-driver.gpg

#===============================================================================
# Step 4: Register the flat APT source
#===============================================================================
echo -e "${YELLOW}[4/7] Registering APT source...${NC}"

cat >/etc/apt/sources.list.d/nvidia-driver.list <<EOF
deb [signed-by=/etc/apt/keyrings/nvidia-driver.gpg] ${RELEASE_BASE} ./
EOF

# Pin our repo over any other source that might also ship nvidia-driver-595
# (e.g., the upstream Pop OS repo with 1pop1 packages).
cat >/etc/apt/preferences.d/nvidia-driver-lwl.pref <<EOF
Package: nvidia-* libnvidia-* xserver-xorg-video-nvidia-* system76-driver-nvidia
Pin: release o=MrScratchcat/nvidia-driver
Pin-Priority: 1001
EOF

apt-get update

#===============================================================================
# Step 5: Install the driver
#===============================================================================
echo -e "${YELLOW}[5/7] Installing ${DRIVER_PKG}...${NC}"

# Verify the package resolves to our repo before we install
RESOLVED=$(apt-cache policy "$DRIVER_PKG" | awk '/Candidate:/ {print $2; exit}')
if [ -z "$RESOLVED" ] || [ "$RESOLVED" = "(none)" ]; then
    echo -e "${RED}Package ${DRIVER_PKG} not found. Did 'apt-get update' succeed?${NC}"
    exit 1
fi
echo "Resolved: $DRIVER_PKG = $RESOLVED"
echo "$RESOLVED" | grep -q '1lwl1' || \
    echo -e "${YELLOW}WARNING: candidate version is not from lwl repo${NC}"

apt-get install -y "$DRIVER_PKG"

#===============================================================================
# Step 6: Force DKMS build + module load
#===============================================================================
echo -e "${YELLOW}[6/7] Building and loading kernel modules...${NC}"

# Force a DKMS rebuild for the running kernel (in case the post-install build
# was skipped because headers landed AFTER the dkms package).
DKMS_VER=$(dkms status 2>/dev/null | awk -F'[:,/ ]+' '/^nvidia/{print $2; exit}')
if [ -n "$DKMS_VER" ]; then
    dkms autoinstall -k "$(uname -r)" >/dev/null 2>&1 || \
        dkms install -m nvidia -v "$DKMS_VER" -k "$(uname -r)" || true
fi

# Unbind nouveau, load nvidia
NVIDIA_PCI=$(lspci -nn | grep "10de:" | grep -E '0300|0302' | awk '{print $1}' | head -1)
if [ -n "$NVIDIA_PCI" ]; then
    PCI_PATH="0000:${NVIDIA_PCI}"
    [ -f "/sys/bus/pci/devices/${PCI_PATH}/power/control" ] && \
        echo on > "/sys/bus/pci/devices/${PCI_PATH}/power/control" 2>/dev/null || true
    if [ -d "/sys/bus/pci/devices/${PCI_PATH}/driver" ]; then
        CUR_DRV=$(basename "$(readlink "/sys/bus/pci/devices/${PCI_PATH}/driver")" 2>/dev/null || true)
        if [ "$CUR_DRV" = "nouveau" ]; then
            echo "Unbinding nouveau from $PCI_PATH..."
            echo "$PCI_PATH" > /sys/bus/pci/drivers/nouveau/unbind 2>/dev/null || true
        fi
    fi
fi
modprobe -r nouveau 2>/dev/null || true
modprobe nvidia 2>/dev/null || true
modprobe nvidia-drm 2>/dev/null || true
modprobe nvidia-uvm 2>/dev/null || true
modprobe nvidia-modeset 2>/dev/null || true
sleep 2

#===============================================================================
# Step 7: Verify
#===============================================================================
echo -e "${YELLOW}[7/7] Verifying...${NC}"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo ""
    nvidia-smi
    echo ""
    echo -e "${GREEN}=== Driver active ===${NC}"
    echo "If you upgraded from another driver, reboot to release the previous module."
    exit 0
fi

# If we got here, modules didn't load — diagnose
echo -e "${YELLOW}nvidia-smi not responding yet. Diagnostics:${NC}"
echo ""
echo "DKMS status:"
dkms status nvidia 2>&1 || true
echo ""
echo "Loaded NVIDIA modules:"
lsmod | grep nvidia || echo "  (none)"
echo ""
echo "Recent dmesg from the kernel module load attempt:"
dmesg | tail -n 30 | grep -iE 'nvidia|nouveau' || dmesg | tail -n 20

echo ""
echo -e "${YELLOW}A reboot usually finishes the job. After reboot, run: nvidia-smi${NC}"
exit 0
