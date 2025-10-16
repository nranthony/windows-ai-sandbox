#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Basic packages
# -----------------------------------------------------------------------------
# NOTE these installs moved to dockerfile
# echo "# ----- Installing base packages -----"
# apt update
# apt install -y \
#      git curl wget fontconfig locales lsd # lsd = pretty ls with icons

# -----------------------------------------------------------------------------
# 1. Zsh & Oh-My-Zsh
# -----------------------------------------------------------------------------
echo "# ----- Installing Zsh and Oh-My-Zsh -----"
# apt install -y zsh
export RUNZSH=no   # don't launch Zsh during unattended install
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# -----------------------------------------------------------------------------
# 2. Powerlevel10k theme
# -----------------------------------------------------------------------------
echo "# ----- Installing Powerlevel10k -----"
if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        "$ZSH_CUSTOM/themes/powerlevel10k"
fi
grep -qxF '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' ~/.zshrc || echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> ~/.zshrc
# -----------------------------------------------------------------------------
# 3. Nerd Fonts (MesloLGS) for icons in prompt & lsd
# -----------------------------------------------------------------------------
echo "# ----- Installing MesloLGS Nerd Fonts -----"
FONT_DIR="$HOME/.local/share/fonts"
mkdir -p "$FONT_DIR"
MESLO_URL="https://github.com/romkatv/powerlevel10k-media/raw/master"
for ttf in "Regular" "Bold" "Italic" "Bold%20Italic"; do
  curl -fsSL "${MESLO_URL}/MesloLGS%20NF%20${ttf}.ttf" \
      -o "${FONT_DIR}/MesloLGS NF ${ttf//%20/ }.ttf"
done
fc-cache -fv  # refresh font cache :contentReference[oaicite:0]{index=0}

# -----------------------------------------------------------------------------
# 4. Oh-My-Zsh plugins (autosuggest, autocomplete, history-substring-search)
# -----------------------------------------------------------------------------
echo "# ----- Installing Zsh plugins -----"
plugins=(
  zsh-users/zsh-autosuggestions
  marlonrichert/zsh-autocomplete
  zsh-users/zsh-history-substring-search
  zsh-users/zsh-syntax-highlighting
)

for repo in "${plugins[@]}"; do
  name="${repo##*/}"
  if [[ ! -d "$ZSH_CUSTOM/plugins/$name" ]]; then
    git clone --depth=1 "https://github.com/${repo}.git" \
        "$ZSH_CUSTOM/plugins/$name"
  fi
done

# -----------------------------------------------------------------------------
# 5. Update ~/.zshrc  (theme, plugins, aliases)
# -----------------------------------------------------------------------------
echo "# ----- Updating ~/.zshrc -----"
sed -i 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$HOME/.zshrc"

# Replace plugin line or append a new one
if grep -q "^plugins=" "$HOME/.zshrc"; then
  sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-autocomplete history-substring-search zsh-syntax-highlighting)/' "$HOME/.zshrc"
else
  echo 'plugins=(git zsh-autosuggestions zsh-autocomplete history-substring-search zsh-syntax-highlighting)' >> "$HOME/.zshrc"
fi

# Pretty, icon-rich directory listings via lsd
grep -qxF 'alias ls="lsd -lah --group-dirs first"' "$HOME/.zshrc" \
  || echo 'alias ls="lsd -lah --group-dirs first"' >> "$HOME/.zshrc"

# -----------------------------------------------------------------------------
# 6. Miniforge (conda / mamba)
#
# This script checks for an existing Miniforge installation. If found, it
# offers to update it. Otherwise, it installs it fresh.
# Note: Python version is set per-environment via environment.yml or manual creation
# -----------------------------------------------------------------------------

MINIFORGE_DIR="$HOME/miniforge3"

# Check if the Miniforge directory already exists
if [ -d "$MINIFORGE_DIR" ]; then
    echo "✅ Miniforge is already installed at: $MINIFORGE_DIR"
    
    # # Prompt the user to update or skip
    # read -p "Do you want to check for updates with 'conda update --all'? (y/N) " -n 1 -r REPLY
    # echo # Move to a new line
    
    # if [[ $REPLY =~ ^[Yy]$ ]]; then
    #     echo "🔄 Updating Conda base environment and packages..."
    #     # Use conda's own update mechanism for safety and efficiency
    #     "$MINIFORGE_DIR/bin/conda" update --all -y
    # else
    #     echo "⏩ Skipping update."
    # fi

else
    echo "# ----- Installing Miniforge -----"
    
    # Perform a fresh installation
    ARCH="$(uname -m)"
    MINIFORGE_INSTALLER="Miniforge3-Linux-${ARCH}.sh"
    INSTALLER_PATH="/tmp/${MINIFORGE_INSTALLER}"
    
    echo "🔽 Downloading ${MINIFORGE_INSTALLER}..."
    curl -L "https://github.com/conda-forge/miniforge/releases/latest/download/${MINIFORGE_INSTALLER}" \
         -o "${INSTALLER_PATH}"
    
    echo "📦 Installing Miniforge to ${MINIFORGE_DIR}..."
    bash "${INSTALLER_PATH}" -b -p "${MINIFORGE_DIR}"
    
    echo "🧹 Cleaning up installer..."
    rm "${INSTALLER_PATH}"
    
    # Initialise conda for Zsh (or bash, fish, etc.)
    # This only needs to run once after the initial installation.
    echo "⚙️ Initialising Conda for Zsh..."
    "$MINIFORGE_DIR/bin/conda" init zsh
    
    echo "✅ Miniforge installation complete."
    echo "⚠️ Please restart your shell or run 'source ~/.zshrc' for the changes to take effect."
fi

# -----------------------------------------------------------------------------
# 7. Done
# -----------------------------------------------------------------------------
echo ""
echo "✅  All finished!  Restart your terminal and let Powerlevel10k guide you"
echo "   through its one-time configuration wizard."

