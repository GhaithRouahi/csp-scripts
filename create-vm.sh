#!/bin/bash

# Script to create a VM with virsh and enable SSH access
# Requires: libvirt, qemu, virt-install, cloud-localds

# Configuration variables
VM_NAME="vm-in"
VM_RAM="2048" # 2GB RAM
VM_CPUS="2"
VM_DISK_SIZE="10G" # 10GB disk
ORIGINAL_CLOUD_IMAGE="$(pwd)/ISOs/ubuntu-cloud.img" # Update this path
SSH_KEY_FILE="$HOME/.ssh/${VM_NAME}_key"

CLOUD_IMAGE="${VM_NAME}.img"

# Copy and resize cloud image
if [ ! -f "${CLOUD_IMAGE}" ]; then
    echo "Creating VM disk..."
    cp "${ORIGINAL_CLOUD_IMAGE}" "${CLOUD_IMAGE}"
fi

# Generate SSH key pair if it doesn't exist
if [ ! -f "${SSH_KEY_FILE}" ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_FILE}" -N "" -q
fi

# Create user-data for cloud-init
echo "Creating cloud-init config..."
cat > user-data <<EOF
#cloud-config
users:
  - name: ubuntu
    ssh-authorized-keys:
      - $(cat "${SSH_KEY_FILE}.pub")
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    passwd: "\$6\$rounds=4096\$aTestSalt\$6kKd/N8aHgR8KhF5yRINYZqK6MN1Fw3AgL4oxJtFb9fKOYP8pOUslKHZevg4AykLGhPtKQIkj/sEaJhsrJ6aI1"  # password: ubuntu

ssh_pwauth: true
disable_root: false

packages:
  - netplan.io
  - openssh-server

write_files:
  - path: /etc/netplan/50-cloud-init.yaml
    content: |
      network:
        version: 2
        ethernets:
          enp1s0:
            dhcp4: true

runcmd:
  - [ netplan, apply ]
  - [ systemctl, restart, ssh ]
EOF

# Create meta-data (empty for basic setup)
echo "instance-id: ${VM_NAME}" > meta-data

# Create cloud-init ISO
echo "Generating cloud-init ISO..."
cloud-localds cloud-init.iso user-data meta-data

# Create the VM
echo "Creating VM ${VM_NAME}..."
virt-install \
    --name "${VM_NAME}" \
    --memory ${VM_RAM} \
    --vcpus ${VM_CPUS} \
    --disk path="${CLOUD_IMAGE},format=qcow2" \
    --disk path=cloud-init.iso,device=cdrom \
    --os-type linux \
    --os-variant ubuntu20.04 \
    --network network=default \
    --graphics none \
    --import \
    --check path_in_use=off \
    --noautoconsole

echo "VM ${VM_NAME} created. Waiting for it to boot and get an IP..."

# Wait for VM to get an IP (this might take a couple of minutes)
IP_ADDRESS=""
while [ -z "${IP_ADDRESS}" ]; do
    IP_ADDRESS=$(virsh domifaddr "${VM_NAME}" | awk -F'[ /]+' '/ipv4/ {print $5}')
    sleep 10
done

# Clean up cloud-init files
rm -f user-data meta-data cloud-init.iso

# Output connection information
echo ""
echo "VM successfully created!"
echo "VM Name: ${VM_NAME}"
echo "IP Address: ${IP_ADDRESS}"
echo "SSH Private Key: ${SSH_KEY_FILE}"
echo ""
echo "To connect to the VM:"
echo "ssh -i ${SSH_KEY_FILE} ubuntu@${IP_ADDRESS}"