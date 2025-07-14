# VM Creation Scripts for LAN Bridge Networking

This repository contains scripts to create and manage Ubuntu virtual machines with LAN bridge networking, making them accessible from anywhere on your local network.

## 📋 Overview

The main script `vm-inside.sh` creates Ubuntu VMs that:
- ✅ Are accessible via SSH from anywhere on your LAN
- ✅ Have static IP addresses on your LAN subnet
- ✅ Include both SSH key and password authentication
- ✅ Automatically detect network configuration
- ✅ Fall back to DHCP if static IP fails
- ✅ Provide comprehensive connectivity testing

## 🛠️ Prerequisites

### Required Tools
The script will check for these tools and guide you to install them if missing:

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install libvirt-bin virtinst cloud-utils qemu-utils bridge-utils netcat
```

**RHEL/CentOS:**
```bash
sudo yum install libvirt virt-install cloud-utils qemu-img bridge-utils nc
```

### Required Files
- **Ubuntu Cloud Image**: Download the Ubuntu cloud image:
```bash
mkdir -p ISOs
cd ISOs
wget https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img -O ubuntu-cloud.img
cd ..
```

### Network Requirements
- A bridge interface (`br0`) must exist on your host
- The bridge should be connected to your LAN
- Your host should have an IP on the same subnet where you want to create VMs

## 🚀 Usage

### Basic Usage
```bash
chmod +x vm-inside.sh
./vm-inside.sh
```

The script will prompt you for:
- VM name (default: `ubuntu-cloud-vm`)
- RAM in MB (default: `2048`)
- Number of CPUs (default: `2`)
- Disk size (default: `10G`)

### Example Session
```
🚀 VM Creation Script with LAN Bridge Networking
================================================
✅ All required tools are available
Please provide VM configuration (press Enter to accept defaults)
Enter VM name [ubuntu-cloud-vm]: myserver
Enter RAM in MB [2048]: 4096
Enter number of CPUs [2]: 4
Enter disk size [10G]: 20G
```

## 🔧 How It Works

### 1. **Network Auto-Detection**
The script automatically:
- Detects your bridge interface configuration
- Finds an available IP in the same subnet
- Discovers the gateway and DNS servers
- Creates network configuration for the VM

### 2. **VM Creation Process**
1. **Checks prerequisites** (tools, image, bridge)
2. **Generates SSH keys** for secure access
3. **Creates VM disk** from Ubuntu cloud image
4. **Configures cloud-init** with network settings
5. **Creates the VM** using virt-install
6. **Tests connectivity** and provides troubleshooting info

### 3. **Network Configuration**
The VM is configured with:
- **Static IP** on your LAN subnet
- **Fallback to DHCP** if static configuration fails
- **Dynamic interface detection** (works with ens3, eth0, enp1s0, etc.)
- **DNS configuration** from host system

### 4. **Authentication Methods**
- **SSH Key Authentication** (recommended, generated automatically)
- **Password Authentication** (backup method, password: `ubuntu`)
- **Console Access** via `virsh console`

## 📊 Network Configuration Examples

### Example 1: Home Network
```
Host Bridge IP: 192.168.1.100/24
VM IP: 192.168.1.150/24
Gateway: 192.168.1.1
```

### Example 2: Office Network
```
Host Bridge IP: 192.168.10.56/24
VM IP: 192.168.10.120/24
Gateway: 192.168.10.254
```

## 🔍 Connectivity Testing

The script performs comprehensive connectivity tests:

1. **Ping Test**: Verifies basic network connectivity
2. **SSH Port Test**: Checks if SSH service is accessible
3. **Authentication Test**: Tests both key and password authentication
4. **IP Discovery**: Finds VM IP via DHCP leases or ARP table if needed

## 🐛 Troubleshooting

### Common Issues and Solutions

#### 1. Bridge Not Found
```
Error: Bridge interface br0 not found!
```
**Solution**: Create a bridge interface first:
```bash
# Example bridge creation (adjust for your network)
sudo ip link add name br0 type bridge
sudo ip link set br0 up
sudo ip link set eth0 master br0
```

#### 2. VM Not Responding to Ping
**Possible Causes**:
- VM still booting (wait 2-3 minutes)
- Network configuration issue
- IP address conflict

**Debugging Steps**:
```bash
# Check VM status
virsh list --all

# Access VM console
virsh console your-vm-name

# Inside VM, check network:
ip addr show
ip route show
ping 8.8.8.8
```

#### 3. SSH Connection Fails
**Possible Causes**:
- SSH service not started yet
- Key authentication issue
- Firewall blocking port 22

**Alternative Connection**:
```bash
# Try password authentication
ssh ubuntu@vm-ip-address
# Password: ubuntu

# Or use console
virsh console your-vm-name
```

## 🧪 Testing VM Connectivity

Use the included test script to verify VM connectivity:

```bash
chmod +x test-vm-connectivity.sh
./test-vm-connectivity.sh your-vm-name
```

This script will:
- Check VM status
- Discover VM IP address
- Test ping and SSH connectivity
- Provide troubleshooting information

## 📁 File Structure

```
csp-scripts/
├── vm-inside.sh              # Main VM creation script
├── test-vm-connectivity.sh   # Connectivity testing script
├── vm-creation-bridge.sh     # Alternative VM creation script
├── vm-outside.sh             # External network VM script
├── create-vm.sh              # Basic VM creation script
├── logs.txt                  # Example execution logs
├── README.md                 # This documentation
└── ISOs/                     # Directory for cloud images
    └── ubuntu-cloud.img      # Ubuntu cloud image (download required)
```

## 🔐 Security Features

- **SSH Key Authentication**: Automatically generated 4096-bit RSA keys
- **Sudo Access**: User has passwordless sudo for convenience
- **Firewall Ready**: Compatible with UFW and iptables
- **Secure Defaults**: Only necessary services enabled

## 🌐 Network Access

Once created, your VM is accessible from:
- **Host machine**: `ssh -i ~/.ssh/vm-name_key ubuntu@vm-ip`
- **Any LAN device**: `ssh ubuntu@vm-ip` (password: ubuntu)
- **Console access**: `virsh console vm-name`

## 📝 Example Output

```
========================================
VM CREATION SUMMARY
========================================
VM Name: myserver
LAN IP Address: 192.168.10.120/24
Gateway: 192.168.10.254
DNS Servers: 8.8.8.8,8.8.4.4
SSH Private Key: /home/user/.ssh/myserver_key
Bridge Interface: br0

Connection command:
ssh -i /home/user/.ssh/myserver_key ubuntu@192.168.10.120

✅ VM is ready and accessible via SSH!

You can now connect to your VM from anywhere on the LAN:
- From this host: ssh -i /home/user/.ssh/myserver_key ubuntu@192.168.10.120
- From other LAN devices: ssh ubuntu@192.168.10.120 (password: ubuntu)
```

## 🔄 VM Management Commands

```bash
# List all VMs
virsh list --all

# Start VM
virsh start vm-name

# Stop VM
virsh shutdown vm-name

# Force stop VM
virsh destroy vm-name

# Delete VM (WARNING: This removes the VM completely)
virsh undefine vm-name --remove-all-storage

# Access VM console
virsh console vm-name
# (Press Ctrl+] to exit console)

# Get VM info
virsh dominfo vm-name
```

## 🎯 Use Cases

This script is perfect for:
- **Development environments**: Isolated test systems accessible from your LAN
- **Learning labs**: Create multiple VMs for networking or security practice
- **Home servers**: Set up services accessible from your home network
- **CI/CD runners**: Isolated build environments
- **Network testing**: Create VMs for testing network configurations

## 🤝 Contributing

Feel free to submit issues, suggestions, or improvements to make these scripts even better!

## 📄 License

This project is open source. Use it freely for your VM creation needs.
