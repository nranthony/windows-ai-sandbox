set -euo pipefail

# -----------------------------------------------------------------------------
# 1. zsh and ohmyzsh
# -----------------------------------------------------------------------------
echo "# ----- Installing Zsh and Oh My Zsh -----"
sudo apt update
apt install zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"



