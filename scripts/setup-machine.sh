#!/bin/bash

# Ansible Bootstrap Script for Laptop Setup
# Supports macOS and various Linux distributions
# Usage: ./bootstrap.sh [playbook_url]
# /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dinoschristou/infra/refs/heads/main/scripts/setup-machine.sh)"

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default playbook URL (replace with your actual playbook repository)
DEFAULT_PLAYBOOK_URL="https://raw.githubusercontent.com/dinoschristou/infra/refs/heads/main/playbooks/daily-driver.yml"

# Configuration
PLAYBOOK_URL="${1:-$DEFAULT_PLAYBOOK_URL}"
TEMP_DIR="/tmp/laptop-setup-$(date +%s)"
PLAYBOOK_FILE="$TEMP_DIR/playbook.yml"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect OS and package manager
detect_system() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        PACKAGE_MANAGER="brew"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="linux"
        
        if command -v apt &> /dev/null; then
            PACKAGE_MANAGER="apt"
            DISTRO="debian"
        elif command -v yum &> /dev/null; then
            PACKAGE_MANAGER="yum"
            DISTRO="rhel"
        elif command -v dnf &> /dev/null; then
            PACKAGE_MANAGER="dnf"
            DISTRO="fedora"
        elif command -v pacman &> /dev/null; then
            PACKAGE_MANAGER="pacman"
            DISTRO="arch"
        elif command -v zypper &> /dev/null; then
            PACKAGE_MANAGER="zypper"
            DISTRO="opensuse"
        elif command -v apk &> /dev/null; then
            PACKAGE_MANAGER="apk"
            DISTRO="alpine"
        else
            log_error "Unsupported Linux distribution"
            exit 1
        fi
    else
        log_error "Unsupported operating system"
        exit 1
    fi
    
    log_info "Detected OS: $OS ($PACKAGE_MANAGER)"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        log_info "Ansible will prompt for sudo password when needed"
        exit 1
    fi
}

# Install prerequisites
install_prerequisites() {
    log_info "Installing prerequisites..."
    
    case $PACKAGE_MANAGER in
        "apt")
            sudo apt update
            sudo apt install -y curl wget git python3 python3-pip python3-venv
            ;;
        "yum")
            sudo yum update -y
            sudo yum install -y curl wget git python3 python3-pip
            ;;
        "dnf")
            sudo dnf update -y
            sudo dnf install -y curl wget git python3 python3-pip
            ;;
        "pacman")
            sudo pacman -Sy --noconfirm curl wget git python python-pip
            ;;
        "zypper")
            sudo zypper refresh
            sudo zypper install -y curl wget git python3 python3-pip
            ;;
        "apk")
            sudo apk update
            sudo apk add curl wget git python3 py3-pip
            ;;
        "brew")
            # Install Homebrew if not present
            if ! command -v brew &> /dev/null; then
                log_info "Installing Homebrew..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                
                # Add Homebrew to PATH for Apple Silicon Macs
                if [[ $(uname -m) == "arm64" ]]; then
                    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
                    eval "$(/opt/homebrew/bin/brew shellenv)"
                fi
            fi
            
            brew update
            brew install curl wget git python3
            ;;
    esac
    
    log_success "Prerequisites installed"
}

# Install Ansible
install_ansible() {
    log_info "Installing Ansible..."
    
    # Check if Ansible is already installed
    if command -v ansible-playbook &> /dev/null; then
        log_info "Ansible is already installed ($(ansible --version | head -n1))"
        return 0
    fi
    
    case $PACKAGE_MANAGER in
        "apt")
            # Install from official Ansible PPA for latest version
            sudo apt update
            sudo apt install -y software-properties-common
            sudo add-apt-repository --yes --update ppa:ansible/ansible
            sudo apt install -y ansible
            ;;
        "yum")
            # Enable EPEL repository first
            sudo yum install -y epel-release
            sudo yum install -y ansible
            ;;
        "dnf")
            sudo dnf install -y ansible
            ;;
        "pacman")
            sudo pacman -S --noconfirm ansible
            ;;
        "zypper")
            sudo zypper install -y ansible
            ;;
        "apk")
            sudo apk add ansible
            ;;
        "brew")
            brew install ansible
            ;;
        *)
            # Fallback to pip installation
            log_warning "Installing Ansible via pip as fallback"
            python3 -m pip install --user ansible
            
            # Ensure pip installed binaries are in PATH
            if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
                export PATH="$HOME/.local/bin:$PATH"
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
            fi
            ;;
    esac
    
    # Verify installation
    if command -v ansible-playbook &> /dev/null; then
        log_success "Ansible installed successfully ($(ansible --version | head -n1))"
    else
        log_error "Failed to install Ansible"
        exit 1
    fi
}

# Download playbook
download_playbook() {
    log_info "Downloading playbook from: $PLAYBOOK_URL"
    
    # Create temporary directory
    mkdir -p "$TEMP_DIR"
    
    # Download the playbook
    if curl -fsSL "$PLAYBOOK_URL" -o "$PLAYBOOK_FILE"; then
        log_success "Playbook downloaded successfully"
    else
        log_error "Failed to download playbook from $PLAYBOOK_URL"
        exit 1
    fi
    
    # Verify it's a valid YAML file
    if ! python3 -c "import yaml; yaml.safe_load(open('$PLAYBOOK_FILE'))" 2>/dev/null; then
        log_error "Downloaded file is not valid YAML"
        exit 1
    fi
}

# Run Ansible playbook
run_playbook() {
    log_info "Running Ansible playbook..."
    
    # Check if sudo is available and working
    if ! sudo -n true 2>/dev/null; then
        log_info "Sudo access required for playbook execution"
        log_info "You may be prompted for your password"
    fi
    
    # Create ansible.cfg in temp directory for this run
    cat > "$TEMP_DIR/ansible.cfg" << 'EOF'
[defaults]
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
callback_whitelist = profile_tasks
inventory = localhost,
timeout = 30

[ssh_connection]
pipelining = True
EOF
    
    # Run the playbook
    cd "$TEMP_DIR"
    
    if ansible-playbook \
        --inventory localhost, \
        --connection local \
        --ask-become-pass \
        "$PLAYBOOK_FILE"; then
        log_success "Playbook executed successfully"
    else
        log_error "Playbook execution failed"
        exit 1
    fi
}

# Cleanup
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 [playbook_url]

Arguments:
    playbook_url    URL to the Ansible playbook (optional)
                   Default: $DEFAULT_PLAYBOOK_URL

Examples:
    $0
    $0 https://raw.githubusercontent.com/user/repo/main/setup.yml
    $0 https://gist.githubusercontent.com/user/id/raw/playbook.yml

The playbook will be run with sudo privileges for system-level changes.
EOF
}

# Main function
main() {
    # Handle help flag
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    log_info "Starting laptop setup with Ansible..."
    log_info "Playbook URL: $PLAYBOOK_URL"
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    # Run setup steps
    check_root
    detect_system
    install_prerequisites
    install_ansible
    download_playbook
    run_playbook
    
    log_success "Laptop setup completed successfully!"
    log_info "Check the output above for any warnings or additional steps needed"
}

# Run main function with all arguments
main "$@"