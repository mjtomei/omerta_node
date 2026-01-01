#!/usr/bin/env bash
# Omerta Installation Script
# Installs Omerta and its dependencies

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

# Detect OS and architecture
detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Darwin)
            PLATFORM="macos"
            ;;
        Linux)
            PLATFORM="linux"
            ;;
        *)
            log_error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac

    log_info "Detected platform: $PLATFORM ($ARCH)"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install WireGuard on macOS
install_wireguard_macos() {
    log_info "Installing WireGuard on macOS..."

    if command_exists brew; then
        brew install wireguard-tools
        log_success "WireGuard installed via Homebrew"
    else
        log_warning "Homebrew not found"
        log_info "Please install Homebrew first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        log_info "Then run this script again"
        exit 1
    fi
}

# Install WireGuard on Linux
install_wireguard_linux() {
    log_info "Installing WireGuard on Linux..."

    # Detect Linux distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
    else
        log_error "Cannot detect Linux distribution"
        exit 1
    fi

    case "$DISTRO" in
        ubuntu|debian)
            log_info "Detected Debian/Ubuntu"
            sudo apt-get update
            sudo apt-get install -y wireguard-tools
            log_success "WireGuard installed via apt"
            ;;
        fedora|rhel|centos)
            log_info "Detected Fedora/RHEL/CentOS"
            sudo dnf install -y wireguard-tools
            log_success "WireGuard installed via dnf"
            ;;
        arch|manjaro)
            log_info "Detected Arch/Manjaro"
            sudo pacman -S --noconfirm wireguard-tools
            log_success "WireGuard installed via pacman"
            ;;
        *)
            log_error "Unsupported Linux distribution: $DISTRO"
            log_info "Please install wireguard-tools manually"
            exit 1
            ;;
    esac
}

# Check WireGuard installation
check_wireguard() {
    log_info "Checking WireGuard installation..."

    if command_exists wg && command_exists wg-quick; then
        WG_VERSION=$(wg --version 2>&1 | head -n1)
        log_success "WireGuard is installed: $WG_VERSION"
        return 0
    else
        log_warning "WireGuard is not installed"
        return 1
    fi
}

# Install WireGuard
install_wireguard() {
    if check_wireguard; then
        log_info "WireGuard already installed, skipping..."
        return 0
    fi

    case "$PLATFORM" in
        macos)
            install_wireguard_macos
            ;;
        linux)
            install_wireguard_linux
            ;;
    esac

    # Verify installation
    if check_wireguard; then
        log_success "WireGuard installation successful"
    else
        log_error "WireGuard installation failed"
        exit 1
    fi
}

# Check for Linux kernel (for macOS VM execution)
check_linux_kernel() {
    if [ "$PLATFORM" = "macos" ]; then
        KERNEL_PATH="$HOME/.omerta/kernel/vmlinuz"
        if [ -f "$KERNEL_PATH" ]; then
            log_success "Linux kernel found at $KERNEL_PATH"
        else
            log_warning "Linux kernel not found (required for VM execution)"
            log_info "The kernel will be downloaded on first VM execution"
            log_info "Or you can download it now:"
            echo "  mkdir -p ~/.omerta/kernel"
            echo "  curl -L https://github.com/omerta/kernel/releases/latest/download/vmlinuz -o ~/.omerta/kernel/vmlinuz"
        fi
    fi
}

# Download Omerta binaries (placeholder for future)
install_omerta() {
    log_info "Installing Omerta..."

    # TODO: In the future, download pre-built binaries
    # For now, assume building from source

    if [ -f "./omerta" ]; then
        log_info "Found Omerta binary in current directory"
        INSTALL_DIR="/usr/local/bin"

        if [ -w "$INSTALL_DIR" ]; then
            cp ./omerta "$INSTALL_DIR/omerta"
            cp ./omertad "$INSTALL_DIR/omertad" 2>/dev/null || true
            log_success "Omerta installed to $INSTALL_DIR"
        else
            log_info "Installing to $INSTALL_DIR requires sudo"
            sudo cp ./omerta "$INSTALL_DIR/omerta"
            sudo cp ./omertad "$INSTALL_DIR/omertad" 2>/dev/null || true
            log_success "Omerta installed to $INSTALL_DIR"
        fi
    else
        log_warning "Omerta binary not found in current directory"
        log_info "To build from source:"
        echo "  git clone https://github.com/omerta/omerta.git"
        echo "  cd omerta"
        echo "  swift build -c release"
        echo "  cp .build/release/omerta /usr/local/bin/"
    fi
}

# Check system requirements
check_requirements() {
    log_info "Checking system requirements..."

    # Check macOS version (if on macOS)
    if [ "$PLATFORM" = "macos" ]; then
        MACOS_VERSION=$(sw_vers -productVersion)
        MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)

        if [ "$MACOS_MAJOR" -ge 14 ]; then
            log_success "macOS version $MACOS_VERSION (meets requirement: 14+)"
        else
            log_error "macOS 14 or higher is required (you have $MACOS_VERSION)"
            log_info "Omerta requires Virtualization.framework features from macOS 14+"
            exit 1
        fi
    fi

    # Check if Swift is available (for building from source)
    if command_exists swift; then
        SWIFT_VERSION=$(swift --version 2>&1 | head -n1)
        log_success "Swift is available: $SWIFT_VERSION"
    else
        log_warning "Swift not found (required only for building from source)"
    fi
}

# Create necessary directories
setup_directories() {
    log_info "Setting up directories..."

    mkdir -p "$HOME/.omerta/vpn"
    mkdir -p "$HOME/.omerta/kernel"
    mkdir -p "$HOME/.omerta/jobs"
    mkdir -p "$HOME/.omerta/logs"

    log_success "Directories created in $HOME/.omerta"
}

# Print summary
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Installation complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Next steps:"
    echo ""

    if command_exists omerta; then
        echo "  1. Check status:"
        echo "     $ omerta status"
        echo ""
        echo "  2. Verify dependencies:"
        echo "     $ omerta check-deps"
        echo ""
        echo "  3. Execute a test job:"
        echo "     $ omerta execute --script 'echo Hello Omerta' --vpn-endpoint <endpoint> --vpn-server-ip <ip> --vpn-config <path>"
    else
        echo "  1. Add Omerta to your PATH if not already:"
        echo "     export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
        echo "  2. Or build from source:"
        echo "     git clone https://github.com/omerta/omerta.git"
        echo "     cd omerta"
        echo "     swift build -c release"
    fi

    echo ""
    log_info "Documentation: https://github.com/omerta/omerta"
    log_info "Issues: https://github.com/omerta/omerta/issues"
    echo ""
}

# Main installation flow
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Omerta Installation Script"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    detect_platform
    check_requirements
    setup_directories
    install_wireguard
    check_linux_kernel
    install_omerta
    print_summary
}

# Run main function
main "$@"
