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

# Create user-data with working netplan config
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
            dhcp4: true

runcmd:
  - [ netplan, apply ]
  - [ systemctl, restart, ssh ]
EOF

# Create meta-data
echo "instance-id: ${VM_NAME}" > meta-data

# Create cloud-init ISO
echo "Generating cloud-init ISO..."
cloud-localds "${CLOUD_INIT_ISO}" user-data meta-data

# Create the VM
echo "Creating VM ${VM_NAME}..."
virt-install \
    --name "${VM_NAME}" \
    --memory ${VM_RAM} \
    --vcpus ${VM_CPUS} \
    --disk path="${CLOUD_IMAGE}",format=qcow2 \
    --disk path="${CLOUD_INIT_ISO}",device=cdrom \
    --os-variant ubuntu20.04 \
    --network network=default \
    --graphics none \
    --import \
    --check path_in_use=off \
    --noautoconsole

echo "VM ${VM_NAME} created. Waiting for it to boot and get an IP..."

# Wait for IP
IP_ADDRESS=""
for i in {1..30}; do
    IP_ADDRESS=$(virsh domifaddr "${VM_NAME}" | awk -F'[ /]+' '/ipv4/ {print $5}')
    [ -n "${IP_ADDRESS}" ] && break
    sleep 5
done

# Clean up cloud-init files
rm -f user-data meta-data "${CLOUD_INIT_ISO}"
omifaddr 
# Output info
echo ""
echo "VM successfully created in default NAT network!"
echo "VM Name: ${VM_NAME}"
echo "Private IP Address: ${IP_ADDRESS:-Not Found}"
echo "SSH Private Key: ${SSH_KEY_FILE}"
echo "To connect:"
echo "1. First connect to your host machine"
echo "2. Then from host: ssh -i ${SSH_KEY_FILE} ubuntu@${IP_ADDRESS}"
echo ""
echo "Note: This VM uses the default NAT network and is not directly exposed to your LAN."
echo "To enable LAN access, you would need to set up port forwarding on the host."