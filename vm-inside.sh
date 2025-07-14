#!/bin/bash

# Function to prompt for input with default value
prompt_input() {
    local prompt="$1"
    local default="$2"
    local input
    read -p "${prompt} [${default}]: " input
    echo "${input:-$default}"
}

# Prompt for configuration variables
echo "Please provide VM configuration (press Enter to accept defaults)"
VM_NAME=$(prompt_input "Enter VM name" "ubuntu-cloud-vm")
VM_RAM=$(prompt_input "Enter RAM in MB" "2048")
VM_CPUS=$(prompt_input "Enter number of CPUs" "2")
VM_DISK_SIZE=$(prompt_input "Enter disk size" "10G")
ORIGINAL_CLOUD_IMAGE=$(pwd)/ISOs/ubuntu-cloud.img

# LAN Network Configuration
LAN_IP="192.168.10.120/24"
LAN_GATEWAY="192.168.10.254"
LAN_DNS="8.8.8.8,8.8.4.4"  # Can use your local DNS if available
LAN_BRIDGE="br0"           # Change to your host's bridge interface

# Set variables
SSH_KEY_FILE="$HOME/.ssh/${VM_NAME}_key"
CLOUD_IMAGE="$(pwd)/ISOs/${VM_NAME}.img"
CLOUD_INIT_ISO="cloud-init-${VM_NAME}.iso"

# Check if VM exists
if virsh list --all | grep -q "${VM_NAME}"; then
    echo "Error: VM '${VM_NAME}' already exists."
    exit 1
fi

# Validate VM name
if [[ ! "${VM_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid VM name. Use letters, numbers, hyphens, underscores."
    exit 1
fi

# Generate SSH key if not exists
if [ ! -f "${SSH_KEY_FILE}" ]; then
    echo "Generating SSH key..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_FILE}" -N "" -q
fi

# Copy and resize cloud image
if [ ! -f "${CLOUD_IMAGE}" ]; then
    echo "Creating VM disk..."
    cp "${ORIGINAL_CLOUD_IMAGE}" "${CLOUD_IMAGE}"
    qemu-img resize "${CLOUD_IMAGE}" "${VM_DISK_SIZE}"
fi

# Create user-data with LAN network config
cat > user-data <<EOF
#cloud-config
users:
  - name: ubuntu
    ssh-authorized-keys:
      - $(cat "${SSH_KEY_FILE}.pub")
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    groups: sudo
    lock_passwd: false
    passwd: "\$6\$rounds=4096\$aTestSalt\$6kKd/N8aHgR8KhF5yRINYZqK6MN1Fw3AgL4oxJtFb9fKOYP8pOUslKHZevg4AykLGhPtKQIkj/sEaJhsrJ6aI1"  # password: ubuntu

ssh_pwauth: true
disable_root: false

packages:
  - qemu-guest-agent
  - netplan.io
  - cloud-init
  - openssh-server

write_files:
  - path: /etc/netplan/50-cloud-init.yaml
    content: |
      network:
        version: 2
        ethernets:
          ens3:
            dhcp4: no
            addresses: [${LAN_IP}]
            routes:
              - to: default
                via: ${LAN_GATEWAY}
            nameservers:
              addresses: [${LAN_DNS//,/,\ }]

runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ netplan, apply ]
  - [ systemctl, restart, ssh ]
  - [ systemctl, restart, cloud-init ]
EOF

# Create meta-data
cat > meta-data <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

# Create cloud-init ISO
echo "Generating cloud-init ISO..."
cloud-localds "${CLOUD_INIT_ISO}" user-data meta-data

# Check if bridge exists
if ! ip link show ${LAN_BRIDGE} >/dev/null 2>&1; then
    echo "Error: Bridge interface ${LAN_BRIDGE} not found!"
    echo "Please create it first or specify an existing bridge."
    echo "Common bridge creation steps:"
    echo "1. Edit /etc/network/interfaces or use nmcli"
    echo "2. Bridge your physical interface (e.g., eth0)"
    exit 1
fi

# Create the VM with bridged network
echo "Creating VM ${VM_NAME} with LAN bridge ${LAN_BRIDGE}..."
virt-install \
    --name "${VM_NAME}" \
    --memory ${VM_RAM} \
    --vcpus ${VM_CPUS} \
    --disk path="${CLOUD_IMAGE}",format=qcow2 \
    --disk path="${CLOUD_INIT_ISO}",device=cdrom \
    --os-variant ubuntu20.04 \
    --network bridge=${LAN_BRIDGE},model=virtio \
    --graphics none \
    --import \
    --check path_in_use=off \
    --noautoconsole

echo "VM ${VM_NAME} created with LAN IP ${LAN_IP}."

# Wait for VM to boot
echo "Waiting for VM to initialize (30 seconds)..."
sleep 30

# Verify connectivity
echo "Testing LAN connectivity..."
if ping -c 3 ${LAN_IP%/*} >/dev/null 2>&1; then
    echo "Ping successful to ${LAN_IP%/*}"
    
    echo "Testing SSH connection..."
    if ssh -i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${LAN_IP%/*} true; then
        echo "SSH connection successful!"
    else
        echo "SSH connection failed. VM may still be initializing."
    fi
else
    echo "Ping failed. Troubleshooting steps:"
    echo "1. Check VM status: virsh list"
    echo "2. View console: virsh console ${VM_NAME}"
    echo "3. Verify network config in VM: ip a"
    echo "4. Check bridge config on host: brctl show ${LAN_BRIDGE}"
fi

# Clean up cloud-init files
rm -f user-data meta-data "${CLOUD_INIT_ISO}"

# Output info
echo ""
echo "VM successfully created with LAN connectivity!"
echo "VM Name: ${VM_NAME}"
echo "LAN IP Address: ${LAN_IP}"
echo "Gateway: ${LAN_GATEWAY}"
echo "DNS Servers: ${LAN_DNS}"
echo "SSH Private Key: ${SSH_KEY_FILE}"
echo "To connect: ssh -i ${SSH_KEY_FILE} ubuntu@${LAN_IP%/*}"
echo ""
echo "Note: Ensure your LAN network matches this configuration:"
echo "- IP range: 192.168.10.0/24"
echo "- Gateway: 192.168.10.254 must be accessible"