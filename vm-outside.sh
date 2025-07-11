#!/bin/bash

# Script to create a VM with bridged networking for LAN access
# Requirements: libvirt, qemu, virt-install, cloud-localds, bridge-utils, openssl

# === Prompt for configuration ===
read -p "Enter VM name [vm99]: " VM_NAME
VM_NAME=${VM_NAME:-vm99}
read -p "Enter RAM in MB [2048]: " VM_RAM
VM_RAM=${VM_RAM:-2048}
read -p "Enter number of CPUs [2]: " VM_CPUS
VM_CPUS=${VM_CPUS:-2}
read -p "Enter disk size [10G]: " VM_DISK_SIZE
VM_DISK_SIZE=${VM_DISK_SIZE:-10G}

# === Configuration ===
ORIGINAL_CLOUD_IMAGE="$(pwd)/ISOs/ubuntu-cloud.img" # Update path if needed
SSH_KEY_FILE="$HOME/.ssh/${VM_NAME}_key"
BRIDGE_NAME="br0"
LOG_FILE="vm_inventory.csv"
CLOUD_IMAGE="${VM_NAME}.img"

# Copy and resize cloud image
if [ ! -f "${CLOUD_IMAGE}" ]; then
    echo "Creating VM disk..."
    cp "${ORIGINAL_CLOUD_IMAGE}" "${CLOUD_IMAGE}"
fi

# === Ensure bridge exists ===
if ! ip link show type bridge | grep -q "$BRIDGE_NAME"; then
    echo "Creating bridge $BRIDGE_NAME..."
    sudo ip link add "$BRIDGE_NAME" type bridge
    sudo ip link set "$BRIDGE_NAME" up

    PHYSICAL_IFACE=$(ip link | awk -F: '$0 !~ "lo|virbr|^[^0-9]"{print $2; exit}' | xargs)
    if [ -n "$PHYSICAL_IFACE" ]; then
        echo "Adding physical interface $PHYSICAL_IFACE to bridge..."
        sudo ip link set "$PHYSICAL_IFACE" up
        sudo ip link set "$PHYSICAL_IFACE" master "$BRIDGE_NAME"
        sudo dhclient "$BRIDGE_NAME"
    else
        echo "Warning: No physical interface found to bridge!"
    fi
fi

# === Generate SSH key if not exists ===
if [ ! -f "${SSH_KEY_FILE}" ]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_FILE}" -N "" -q
fi

# === Generate unique MAC address ===
MAC_ADDRESS=$(printf '52:54:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
echo "Generated MAC address: ${MAC_ADDRESS}"

# === Create cloud-init config ===
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
  - [ netplan, apply ]
EOF

echo "instance-id: ${VM_NAME}" > meta-data
cloud-localds cloud-init.iso user-data meta-data

# === Create the VM ===
echo "Creating VM ${VM_NAME}..."
virt-install \
    --name "${VM_NAME}" \
    --memory ${VM_RAM} \
    --vcpus ${VM_CPUS} \
    --disk path="${CLOUD_IMAGE},format=qcow2,size=${VM_DISK_SIZE//[^0-9]/}" \
    --disk path=cloud-init.iso,device=cdrom \
    --os-type linux \
    --os-variant ubuntu20.04 \
    --network bridge=${BRIDGE_NAME},mac=${MAC_ADDRESS} \
    --graphics none \
    --import \
    --check path_in_use=off \
    --noautoconsole

# === Wait for IP ===
echo "Waiting for VM to boot and get an IP..."
IP_ADDRESS=""
ATTEMPTS=0
MAX_ATTEMPTS=12

while [ -z "${IP_ADDRESS}" ] && [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    GUEST_MAC=$(virsh domiflist "${VM_NAME}" | awk '{print $5}' | grep -iE '([0-9a-f]{2}:){5}[0-9a-f]{2}')
    IP_ADDRESS=$(sudo arp -an | grep "$GUEST_MAC" | awk '{gsub(/[()]/,""); print $2}')

    if [ -z "$IP_ADDRESS" ]; then
        echo "Waiting (attempt $((ATTEMPTS+1))/$MAX_ATTEMPTS)..."
        sleep 10
        ((ATTEMPTS++))
    fi
done

# === Clean cloud-init ===
rm -f user-data meta-data cloud-init.iso

# === Output ===
echo ""
if [ -n "${IP_ADDRESS}" ]; then
    echo "✅ VM '${VM_NAME}' created and connected to LAN!"
    echo "🌐 IP Address: ${IP_ADDRESS}"
    echo "🔑 SSH Private Key: ${SSH_KEY_FILE}"
    echo ""
    echo "To connect: ssh -i ${SSH_KEY_FILE} ubuntu@${IP_ADDRESS}"

    # Log to CSV
    echo "${VM_NAME},${MAC_ADDRESS},${IP_ADDRESS}" >> "${LOG_FILE}"
else
    echo "⚠️ VM '${VM_NAME}' created but no IP address detected."
    echo "You may need to check your network or get the IP from your router."
fi
