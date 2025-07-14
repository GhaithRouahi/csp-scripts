#!/bin/bash

# VM Connectivity Test Script
# Use this script to test connectivity to a VM created with vm-inside.sh

if [ $# -eq 0 ]; then
    echo "Usage: $0 <VM_NAME> [IP_ADDRESS]"
    echo "Example: $0 myvm"
    echo "Example: $0 myvm 192.168.10.120"
    exit 1
fi

VM_NAME="$1"
VM_IP="$2"

echo "🔍 Testing connectivity to VM: ${VM_NAME}"
echo "========================================"

# Check if VM exists and is running
echo "1. Checking VM status..."
if ! virsh list --all | grep -q "${VM_NAME}"; then
    echo "   ❌ VM '${VM_NAME}' not found"
    echo "   Available VMs:"
    virsh list --all
    exit 1
fi

VM_STATE=$(virsh list --all | grep "${VM_NAME}" | awk '{print $3}')
echo "   VM State: ${VM_STATE}"

if [ "${VM_STATE}" != "running" ]; then
    echo "   ⚠️  VM is not running. Starting VM..."
    virsh start "${VM_NAME}"
    echo "   Waiting for VM to boot (30 seconds)..."
    sleep 30
fi

# Try to determine VM IP if not provided
if [ -z "$VM_IP" ]; then
    echo "2. Discovering VM IP address..."
    
    # Method 1: Check DHCP leases
    if [ -f /var/lib/libvirt/dnsmasq/virbr0.status ]; then
        DHCP_IP=$(grep -A 10 -B 10 "${VM_NAME}" /var/lib/libvirt/dnsmasq/virbr0.status 2>/dev/null | grep "ip-address" | cut -d'"' -f4 | head -1)
        if [ -n "$DHCP_IP" ]; then
            VM_IP="$DHCP_IP"
            echo "   Found IP via DHCP lease: ${VM_IP}"
        fi
    fi
    
    # Method 2: Check ARP table
    if [ -z "$VM_IP" ]; then
        VM_MAC=$(virsh domiflist "${VM_NAME}" 2>/dev/null | grep -E "bridge|network" | awk '{print $5}' | head -1)
        if [ -n "$VM_MAC" ]; then
            ARP_IP=$(arp -a | grep -i "$VM_MAC" | awk '{print $2}' | tr -d '()')
            if [ -n "$ARP_IP" ]; then
                VM_IP="$ARP_IP"
                echo "   Found IP via ARP table: ${VM_IP}"
            fi
        fi
    fi
    
    # Method 3: Check common IP ranges
    if [ -z "$VM_IP" ]; then
        echo "   Scanning common IP ranges..."
        for range in "192.168.122" "192.168.10" "192.168.1"; do
            for i in {100..200}; do
                test_ip="${range}.${i}"
                if ping -c 1 -W 1 "$test_ip" >/dev/null 2>&1; then
                    # Check if this IP belongs to our VM
                    if nc -z -w 2 "$test_ip" 22 >/dev/null 2>&1; then
                        VM_IP="$test_ip"
                        echo "   Found potential IP: ${VM_IP}"
                        break 2
                    fi
                fi
            done
        done
    fi
    
    if [ -z "$VM_IP" ]; then
        echo "   ❌ Could not determine VM IP address"
        echo "   Try checking the VM console: virsh console ${VM_NAME}"
        echo "   Or provide IP manually: $0 ${VM_NAME} <IP_ADDRESS>"
        exit 1
    fi
fi

echo "   Using VM IP: ${VM_IP}"

# Test connectivity
echo "3. Testing network connectivity..."
if ping -c 3 -W 2 "${VM_IP}" >/dev/null 2>&1; then
    echo "   ✅ Ping successful"
else
    echo "   ❌ Ping failed"
    echo "   VM may still be booting or have network issues"
fi

# Test SSH
echo "4. Testing SSH connectivity..."
if nc -z -w 5 "${VM_IP}" 22 >/dev/null 2>&1; then
    echo "   ✅ SSH port (22) is open"
    
    # Try to connect with standard key locations
    for key in "$HOME/.ssh/${VM_NAME}_key" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519"; do
        if [ -f "$key" ]; then
            echo "   Testing SSH with key: $key"
            if ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@"${VM_IP}" "echo 'SSH key auth successful'" 2>/dev/null; then
                echo "   ✅ SSH key authentication successful!"
                echo ""
                echo "   Connection command:"
                echo "   ssh -i $key ubuntu@${VM_IP}"
                break
            fi
        fi
    done
    
    # Try password authentication
    echo "   You can also try password authentication:"
    echo "   ssh ubuntu@${VM_IP}"
    echo "   (default password: ubuntu)"
    
else
    echo "   ❌ SSH port (22) is not accessible"
    echo "   VM may still be booting or SSH service not started"
fi

# Show VM console access
echo ""
echo "5. Console access:"
echo "   virsh console ${VM_NAME}"
echo "   (Press Ctrl+] to exit console)"

# Show VM info
echo ""
echo "6. VM Information:"
echo "   Name: ${VM_NAME}"
echo "   IP: ${VM_IP}"
echo "   MAC: $(virsh domiflist "${VM_NAME}" 2>/dev/null | grep -E "bridge|network" | awk '{print $5}' | head -1)"
echo "   Network: $(virsh domiflist "${VM_NAME}" 2>/dev/null | grep -E "bridge|network" | awk '{print $3}' | head -1)"

echo ""
echo "🔧 Troubleshooting tips:"
echo "   - If ping fails: check VM network configuration (virsh console ${VM_NAME})"
echo "   - If SSH fails: wait a few minutes for VM to fully boot"
echo "   - Check VM logs: journalctl -f (inside VM console)"
echo "   - Restart VM: virsh reboot ${VM_NAME}"
