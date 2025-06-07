# Secure Docker Setup in WSL2 Ubuntu 24

## 1. Install Docker Engine (Not Docker Desktop)

```bash
# Update package index
sudo apt update

# Install prerequisites
# ca-certificates package contains a set of common certificate authorities (CAs) used to verify the authenticity of SSL/TLS connections. These certificates are essential for securely accessing websites and other network services that use HTTPS.
# gnupg package provides the GNU Privacy Guard (GnuPG), a free implementation of the OpenPGP standard. It is used for encryption, digital signatures, and key management. 
# lsb-release package provides a utility to display information about the Linux Standard Base (LSB) and distribution-specific details. It's used to identify the Linux distribution and its version. 
sudo apt install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

## 2. Configure Rootless Docker (Enhanced Security)

```bash
# Install rootless extras
sudo apt install -y uidmap dbus-user-session

# Disable system Docker daemon (we'll run rootless)
sudo systemctl disable --now docker.service docker.socket

# Install rootless Docker for current user
dockerd-rootless-setuptool.sh install

# Add to shell profile for automatic startup
echo 'export PATH=/usr/bin:$PATH' >> ~/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/1000/docker.sock' >> ~/.bashrc
source ~/.bashrc
```

## 3. Configure User Namespace Remapping (Additional Security Layer)

```bash
# Create subuid and subgid mappings
echo "$(whoami):100000:65536" | sudo tee -a /etc/subuid
echo "$(whoami):100000:65536" | sudo tee -a /etc/subgid

# Restart rootless Docker to apply changes
systemctl --user restart docker
```

## 4. Create Secure Docker Configuration

```bash
# Create Docker config directory
mkdir -p ~/.docker

# Create daemon configuration for rootless mode
cat > ~/.docker/daemon.json << 'EOF'
{
  "userns-remap": "default",
  "no-new-privileges": true,
  "seccomp-profile": "/etc/docker/seccomp.json",
  "apparmor-profile": "docker-default",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "hard": 1024,
      "soft": 1024
    },
    "nproc": {
      "hard": 512,
      "soft": 512
    }
  },
  "storage-driver": "overlay2"
}
EOF
```

## 5. Set Up Resource Limits and Security Policies

```bash
# Create a dedicated user for running AI containers (optional but recommended)
sudo useradd -m -s /bin/bash airunner
sudo usermod -aG docker airunner

# Create resource limit configuration
sudo mkdir -p /etc/systemd/system/user@.service.d/
sudo tee /etc/systemd/system/user@.service.d/delegate.conf << 'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF

# Reload systemd
sudo systemctl daemon-reload
```

## 6. Configure Network Security

```bash
# Create custom Docker network with restricted access
docker network create \
  --driver bridge \
  --subnet=172.20.0.0/16 \
  --ip-range=172.20.240.0/20 \
  --gateway=172.20.0.1 \
  --opt com.docker.network.bridge.name=docker-secure \
  ai-sandbox

# Create network policies (requires iptables)
sudo apt install -y iptables-persistent

# Block container-to-host communication (except necessary ports)
sudo iptables -I DOCKER-USER -i docker-secure -j DROP
sudo iptables -I DOCKER-USER -i docker-secure -p tcp --dport 22 -j ACCEPT  # SSH if needed
```

## 7. Create Secure Container Templates

### Basic Secure Container Script
```bash
cat > ~/run-ai-container.sh << 'EOF'
#!/bin/bash

# Default security options
SECURITY_OPTS="--security-opt=no-new-privileges:true"
SECURITY_OPTS="$SECURITY_OPTS --security-opt=apparmor:docker-default"
SECURITY_OPTS="$SECURITY_OPTS --cap-drop=ALL"
SECURITY_OPTS="$SECURITY_OPTS --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID"

# Resource limits
RESOURCE_LIMITS="--memory=4g --cpus=2.0 --pids-limit=512"

# Network and filesystem restrictions
RESTRICTIONS="--network=ai-sandbox --read-only --tmpfs=/tmp:rw,noexec,nosuid,size=1g"

# User remapping
USER_MAP="--user=1000:1000"

# Run container with all security measures
docker run -it --rm \
  $SECURITY_OPTS \
  $RESOURCE_LIMITS \
  $RESTRICTIONS \
  $USER_MAP \
  --name ai-sandbox-$(date +%s) \
  "$@"
EOF

chmod +x ~/run-ai-container.sh
```

### Example Usage
```bash
# Run a secure AI container
./run-ai-container.sh -v /path/to/models:/models:ro ubuntu:24.04 bash

# Run with specific AI framework
./run-ai-container.sh -v /path/to/models:/models:ro pytorch/pytorch:latest python
```

## 8. Additional Security Hardening

### Install and Configure AppArmor Profile
```bash
# Install AppArmor utilities
sudo apt install -y apparmor-utils

# Create custom Docker profile (optional - for advanced users)
sudo aa-genprof docker
```

### Set Up Logging and Monitoring
```bash
# Install audit daemon for container monitoring
sudo apt install -y auditd

# Add audit rules for Docker
echo "-w /usr/bin/docker -p x -k docker" | sudo tee -a /etc/audit/rules.d/docker.rules
sudo systemctl restart auditd
```

### Create Container Health Checks
```bash
cat > ~/check-container-security.sh << 'EOF'
#!/bin/bash
echo "=== Container Security Status ==="
echo "Active containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "\n=== Resource Usage ==="
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}"

echo -e "\n=== Network Connections ==="
sudo netstat -tulpn | grep docker
EOF

chmod +x ~/check-container-security.sh
```

## 9. Startup Configuration

```bash
# Enable rootless Docker to start on boot
systemctl --user enable docker

# Add to .bashrc for convenience
echo 'alias docker-secure="~/run-ai-container.sh"' >> ~/.bashrc
echo 'alias docker-check="~/check-container-security.sh"' >> ~/.bashrc
source ~/.bashrc
```

## 10. Testing Your Setup

```bash
# Test rootless Docker
docker run --rm hello-world

# Test security restrictions
./run-ai-container.sh ubuntu:24.04 whoami  # Should show mapped user

# Test resource limits
./run-ai-container.sh ubuntu:24.04 bash -c "cat /proc/meminfo | grep MemTotal"

# Verify network isolation
docker-check
```

## Important Security Notes

1. **Regular Updates**: Keep Docker and Ubuntu updated
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

2. **Image Security**: Only use trusted base images
   ```bash
   docker pull --platform linux/amd64 ubuntu:24.04
   ```

3. **Volume Mounts**: Always use read-only mounts when possible
   ```bash
   -v /host/path:/container/path:ro
   ```

4. **Secrets Management**: Never put secrets in images or containers
   ```bash
   # Use Docker secrets or environment files
   docker run --env-file .env.secure your-image
   ```

5. **Regular Auditing**: Monitor container activity
   ```bash
   # Check for suspicious activity
   sudo ausearch -k docker | tail -20
   ```

This setup provides multiple layers of security isolation while maintaining usability for AI model experimentation.