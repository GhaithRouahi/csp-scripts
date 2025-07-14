#!/bin/bash

# VM Creation Script with LAN Bridge Networking
# This script creates a Ubuntu VM with static IP on your LAN

# Check required tools
check_requirements() {
    local missing_tools=()
    
    command -v virsh >/dev/null 2>&1 || missing_tools+=("libvirt-bin")
    command -v virt-install >/dev/null 2>&1 || missing_tools+=("virtinst")
    command -v cloud-localds >/dev/null 2>&1 || missing_tools+=("cloud-utils")
    command -v qemu-img >/dev/null 2>&1 || missing_tools+=("qemu-utils")
    command -v brctl >/dev/null 2>&1 || missing_tools+=("bridge-utils")
    command -v nc >/dev/null 2>&1 || missing_tools+=("netcat")
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo "❌ Missing required tools. Please install:"
        printf '   %s\n' "${missing_tools[@]}"
        echo ""
        echo "On Ubuntu/Debian:"
        echo "sudo apt update"
        echo "sudo apt install libvirt-bin virtinst cloud-utils qemu-utils bridge-utils netcat"
        echo ""
        echo "On RHEL/CentOS:"
        echo "sudo yum install libvirt virt-install cloud-utils qemu-img bridge-utils nc"
        exit 1
    fi
    
    # Check if libvirt is running
    if ! systemctl is-active --quiet libvirtd; then
        echo "❌ libvirtd service is not running. Please start it:"
        echo "sudo systemctl start libvirtd"
        echo "sudo systemctl enable libvirtd"
        exit 1
    fi
    
    echo "✅ All required tools are available"
}

echo "🚀 VM Creation Script with LAN Bridge Networking"
echo "================================================"
check_requirements

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

# Check if the base Ubuntu cloud image exists
if [ ! -f "${ORIGINAL_CLOUD_IMAGE}" ]; then
    echo "❌ Ubuntu cloud image not found at: ${ORIGINAL_CLOUD_IMAGE}"
    echo ""
    echo "Please download Ubuntu cloud image first:"
    echo "mkdir -p $(pwd)/ISOs"
    echo "cd $(pwd)/ISOs"
    echo "wget https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img -O ubuntu-cloud.img"
    echo "cd .."
    echo ""
    echo "Or update ORIGINAL_CLOUD_IMAGE variable to point to your existing image."
    exit 1
fi

echo "✅ Found Ubuntu cloud image at: ${ORIGINAL_CLOUD_IMAGE}"

# LAN Network Configuration - Auto-detect from host bridge
LAN_BRIDGE="br0"           # Change to your host's bridge interface

# Auto-detect network configuration from host bridge
get_bridge_network_config() {
    local bridge_ip=$(ip addr show ${LAN_BRIDGE} | grep "inet " | awk '{print $2}' | head -1)
    if [ -z "$bridge_ip" ]; then
        echo "Error: Could not detect IP configuration for bridge ${LAN_BRIDGE}"
        exit 1
    fi
    
    local network=$(echo $bridge_ip | cut -d'.' -f1-3)
    local host_ip=$(echo $bridge_ip | cut -d'/' -f1)
    local subnet_mask=$(echo $bridge_ip | cut -d'/' -f2)
    
    # Find an available IP in the same subnet
    for i in {100..200}; do
        local test_ip="${network}.$i"
        if [ "$test_ip" != "$host_ip" ] && ! ping -c 1 -W 1 "$test_ip" >/dev/null 2>&1; then
            LAN_IP="${test_ip}/${subnet_mask}"
            break
        fi
    done
    
    # Try to detect gateway (usually .1 or .254 in the subnet)
    local potential_gateways=("${network}.1" "${network}.254")
    for gw in "${potential_gateways[@]}"; do
        if ping -c 1 -W 1 "$gw" >/dev/null 2>&1; then
            LAN_GATEWAY="$gw"
            break
        fi
    done
    
    # Fallback to host's default gateway if not found
    if [ -z "$LAN_GATEWAY" ]; then
        LAN_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
    fi
    
    # Use host's DNS servers
    LAN_DNS=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    if [ -z "$LAN_DNS" ]; then
        LAN_DNS="8.8.8.8,8.8.4.4"  # Fallback to Google DNS
    fi
}

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

# Auto-detect network configuration
echo "Auto-detecting network configuration from bridge ${LAN_BRIDGE}..."
get_bridge_network_config
echo "Detected network config:"
echo "  IP: ${LAN_IP}"
echo "  Gateway: ${LAN_GATEWAY}"
echo "  DNS: ${LAN_DNS}"

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
          enp1s0:
            dhcp4: no
            addresses: [${LAN_IP}]
            routes:
              - to: default
                via: ${LAN_GATEWAY}
            nameservers:
              addresses: [${LAN_DNS//,/,\ }]
          ens3:
            dhcp4: no
            addresses: [${LAN_IP}]
            routes:
              - to: default
                via: ${LAN_GATEWAY}
            nameservers:
              addresses: [${LAN_DNS//,/,\ }]
          eth0:
            dhcp4: no
            addresses: [${LAN_IP}]
            routes:
              - to: default
                via: ${LAN_GATEWAY}
            nameservers:
              addresses: [${LAN_DNS//,/,\ }]
  - path: /usr/local/bin/setup-network.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Dynamic network interface setup with fallback to DHCP
      
      echo "Starting network setup..."
      
      # Find the primary network interface (exclude loopback)
      PRIMARY_IFACE=\$(ip route | grep default | awk '{print \$5}' | head -1)
      if [ -z "\$PRIMARY_IFACE" ]; then
          # Fallback: find first non-loopback interface
          PRIMARY_IFACE=\$(ip link show | grep -E "^[0-9]+:" | grep -v "lo:" | head -1 | awk -F': ' '{print \$2}')
      fi
      
      if [ -n "\$PRIMARY_IFACE" ]; then
          echo "Setting up network on interface: \$PRIMARY_IFACE"
          
          # First try static IP configuration
          cat > /etc/netplan/60-vm-network.yaml << EOL
      network:
        version: 2
        ethernets:
          \$PRIMARY_IFACE:
            dhcp4: no
            addresses: [${LAN_IP}]
            routes:
              - to: default
                via: ${LAN_GATEWAY}
            nameservers:
              addresses: [${LAN_DNS//,/,\ }]
      EOL
          
          # Remove old configs that might conflict
          rm -f /etc/netplan/50-cloud-init.yaml
          
          # Apply network configuration
          echo "Applying static IP configuration..."
          netplan apply
          
          # Wait and test connectivity
          sleep 10
          if ping -c 2 -W 3 ${LAN_GATEWAY} >/dev/null 2>&1; then
              echo "✅ Static IP configuration successful - gateway reachable"
          else
              echo "⚠️  Static IP failed, falling back to DHCP..."
              
              # Fallback to DHCP
              cat > /etc/netplan/60-vm-network.yaml << EOL
      network:
        version: 2
        ethernets:
          \$PRIMARY_IFACE:
            dhcp4: yes
            nameservers:
              addresses: [${LAN_DNS//,/,\ }]
      EOL
              
              netplan apply
              sleep 10
              
              # Get the DHCP assigned IP
              NEW_IP=\$(ip addr show \$PRIMARY_IFACE | grep "inet " | awk '{print \$2}' | cut -d'/' -f1)
              if [ -n "\$NEW_IP" ]; then
                  echo "✅ DHCP configuration successful - IP: \$NEW_IP"
                  echo "\$NEW_IP" > /tmp/vm-ip.txt
              else
                  echo "❌ Both static and DHCP configuration failed"
              fi
          fi
      else
          echo "❌ Error: Could not detect primary network interface"
      fi

runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ chmod, +x, /usr/local/bin/setup-network.sh ]
  - [ /usr/local/bin/setup-network.sh ]
  - [ systemctl, restart, ssh ]

bootcmd:
  - [ cloud-init-per, once, setup-network, /usr/local/bin/setup-network.sh ]
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

# Wait for VM to boot and network to initialize
echo "Waiting for VM to initialize (60 seconds)..."
sleep 60

# Try to determine the actual VM IP (in case it fell back to DHCP)
VM_IP=${LAN_IP%/*}
echo "Testing connectivity to VM..."

# First try the configured static IP
echo "1. Testing configured IP: ${VM_IP}"
if ping -c 2 -W 2 ${VM_IP} >/dev/null 2>&1; then
    echo "   ✓ VM responds at configured IP: ${VM_IP}"
    PING_SUCCESS=true
else
    echo "   ✗ VM not responding at configured IP"
    
    # Try to find VM IP via DHCP lease or ARP table
    echo "2. Searching for VM IP via DHCP/ARP..."
    
    # Check DHCP leases for libvirt network
    if [ -f /var/lib/libvirt/dnsmasq/virbr0.status ]; then
        DHCP_IP=$(grep -A 10 -B 10 "${VM_NAME}" /var/lib/libvirt/dnsmasq/virbr0.status 2>/dev/null | grep "ip-address" | cut -d'"' -f4 | head -1)
        if [ -n "$DHCP_IP" ] && ping -c 2 -W 2 "$DHCP_IP" >/dev/null 2>&1; then
            VM_IP="$DHCP_IP"
            echo "   ✓ Found VM at DHCP IP: ${VM_IP}"
            PING_SUCCESS=true
        fi
    fi
    
    # If still not found, check ARP table for recent MAC addresses
    if [ "$PING_SUCCESS" != true ]; then
        echo "   Checking ARP table for VM MAC address..."
        VM_MAC=$(virsh domiflist "${VM_NAME}" 2>/dev/null | grep -E "bridge|network" | awk '{print $5}' | head -1)
        if [ -n "$VM_MAC" ]; then
            ARP_IP=$(arp -a | grep -i "$VM_MAC" | awk '{print $2}' | tr -d '()')
            if [ -n "$ARP_IP" ] && ping -c 2 -W 2 "$ARP_IP" >/dev/null 2>&1; then
                VM_IP="$ARP_IP"
                echo "   ✓ Found VM via ARP table: ${VM_IP}"
                PING_SUCCESS=true
            fi
        fi
    fi
    
    if [ "$PING_SUCCESS" != true ]; then
        echo "   ✗ Could not locate VM IP address"
        PING_SUCCESS=false
    fi
fi

# Test SSH connectivity only if ping was successful
if [ "$PING_SUCCESS" = true ]; then
    echo "3. Testing SSH port (22) on ${VM_IP}..."
    if nc -z -w 5 ${VM_IP} 22 >/dev/null 2>&1; then
        echo "   ✓ SSH port is open"
        SSH_PORT_OPEN=true
    else
        echo "   ✗ SSH port is not accessible"
        SSH_PORT_OPEN=false
    fi

    # Test SSH connection
    if [ "$SSH_PORT_OPEN" = true ]; then
        echo "4. Testing SSH authentication..."
        if ssh -i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes ubuntu@${VM_IP} "echo 'SSH connection successful'" 2>/dev/null; then
            echo "   ✓ SSH connection and authentication successful!"
            SSH_SUCCESS=true
        else
            echo "   ✗ SSH authentication failed, trying password authentication..."
            # Test with password (non-interactive test)
            if sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PasswordAuthentication=yes ubuntu@${VM_IP} "echo 'SSH password auth works'" 2>/dev/null; then
                echo "   ✓ SSH password authentication works"
                SSH_SUCCESS=true
            else
                echo "   ✗ Both key and password authentication failed"
                SSH_SUCCESS=false
            fi
        fi
    else
        echo "4. Skipping SSH test (port not open)"
        SSH_SUCCESS=false
    fi
else
    echo "3. Skipping SSH tests (VM not reachable)"
    SSH_PORT_OPEN=false
    SSH_SUCCESS=false
fi

# Troubleshooting section
if [ "$PING_SUCCESS" = false ] || [ "$SSH_SUCCESS" = false ]; then
    echo ""
    echo "🔧 TROUBLESHOOTING INFORMATION:"
    echo "==============================================="
    
    echo "Host network configuration:"
    echo "- Bridge ${LAN_BRIDGE} status:"
    ip addr show ${LAN_BRIDGE} 2>/dev/null || echo "  Bridge not found!"
    
    echo ""
    echo "VM status:"
    virsh list --all | grep ${VM_NAME}
    
    echo ""
    echo "Suggested troubleshooting steps:"
    echo "1. Check VM console output:"
    echo "   virsh console ${VM_NAME}"
    echo "   (Press Ctrl+] to exit console)"
    echo ""
    echo "2. Verify VM network inside guest:"
    echo "   virsh console ${VM_NAME}"
    echo "   Then run: ip addr show"
    echo "            ip route show"
    echo "            ping ${LAN_GATEWAY}"
    echo ""
    echo "3. Check host bridge configuration:"
    echo "   brctl show ${LAN_BRIDGE}"
    echo "   bridge fdb show br ${LAN_BRIDGE}"
    echo ""
    echo "4. Verify firewall settings:"
    echo "   sudo ufw status"
    echo "   sudo iptables -L"
    echo ""
    echo "5. Check if gateway ${LAN_GATEWAY} is reachable from host:"
    echo "   ping ${LAN_GATEWAY}"
    
    if [ "$PING_SUCCESS" = false ]; then
        echo ""
        echo "⚠️  VM is not responding to ping. This could indicate:"
        echo "   - VM is still booting (wait a few more minutes)"
        echo "   - Network configuration issue inside VM"
        echo "   - Bridge/routing problem on host"
        echo "   - IP address conflict"
    fi
    
    if [ "$SSH_SUCCESS" = false ] && [ "$PING_SUCCESS" = true ]; then
        echo ""
        echo "⚠️  VM responds to ping but SSH fails. This could indicate:"
        echo "   - SSH service not started yet (wait a few minutes)"
        echo "   - SSH key authentication issue"
        echo "   - Firewall blocking SSH port"
    fi
fi

# Clean up cloud-init files
rm -f user-data meta-data "${CLOUD_INIT_ISO}"

# Final summary
echo ""
echo "=========================================="
echo "VM CREATION SUMMARY"
echo "=========================================="
echo "VM Name: ${VM_NAME}"
echo "LAN IP Address: ${LAN_IP}"
echo "Gateway: ${LAN_GATEWAY}"
echo "DNS Servers: ${LAN_DNS}"
echo "SSH Private Key: ${SSH_KEY_FILE}"
echo "Bridge Interface: ${LAN_BRIDGE}"
echo ""
echo "Connection command:"
echo "ssh -i ${SSH_KEY_FILE} ubuntu@${VM_IP}"
echo ""
echo "Alternative connection methods:"
echo "1. Using username/password: ssh ubuntu@${VM_IP}"
echo "   (password: ubuntu)"
echo "2. Console access: virsh console ${VM_NAME}"
echo ""

if [ "$SSH_SUCCESS" = true ]; then
    echo "✅ VM is ready and accessible via SSH!"
    echo ""
    echo "You can now connect to your VM from anywhere on the LAN:"
    echo "- From this host: ssh -i ${SSH_KEY_FILE} ubuntu@${VM_IP}"
    echo "- From other LAN devices: ssh ubuntu@${VM_IP} (password: ubuntu)"
    echo ""
    echo "The VM is configured with:"
    echo "- SSH key authentication (recommended)"
    echo "- Password authentication (backup method)"
    echo "- Sudo access without password"
    echo "- Static IP on your LAN subnet"
else
    echo "⚠️  VM created but connectivity needs verification"
    echo "Please wait a few more minutes and test connectivity manually."
    echo ""
    echo "Quick test commands:"
    echo "ping ${VM_IP}"
    echo "ssh -i ${SSH_KEY_FILE} ubuntu@${VM_IP}"
fi

echo ""
echo "Network Configuration Details:"
network_range=$(echo ${LAN_IP} | cut -d'/' -f1 | cut -d'.' -f1-3)
echo "- Network Range: ${network_range}.0/$(echo ${LAN_IP} | cut -d'/' -f2)"
echo "- VM IP: ${VM_IP}"
echo "- Host Bridge IP: $(ip addr show ${LAN_BRIDGE} | grep 'inet ' | awk '{print $2}' | head -1)"
echo "- Gateway: ${LAN_GATEWAY}"