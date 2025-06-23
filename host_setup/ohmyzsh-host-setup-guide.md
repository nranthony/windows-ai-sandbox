# ohmyzsh-host-setup.sh – Annotated Guide  
*Updated: 23 Jun 2025*

This guide describes how **`ohmyzsh-host-setup.sh`** transforms a fresh Ubuntu‑on‑WSL installation into a pleasant, productivity‑oriented shell environment.

---

## 1. Base Packages  

```bash
sudo apt update
sudo apt install -y git curl wget fontconfig locales lsd
```

* **`lsd`** replaces `ls` with icons, colours, and a modern flag set.  
* `fontconfig` and `locales` ensure Nerd‑Fonts and UTF‑8 glyphs display correctly.

---

## 2. Zsh & Oh‑My‑Zsh  

The script:

1. Installs `zsh` and sets it as the default login shell with `chsh -s $(which zsh)`.  
2. Downloads Oh‑My‑Zsh unattended (`RUNZSH=no`) to `~/.oh-my-zsh`.

If Zsh or Oh‑My‑Zsh already exists the blocks are skipped, so the script is **idempotent**.

---

## 3. Powerlevel10k Prompt  

```bash
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
     "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
```

A pre‑tuned `.p10k.zsh` is copied over enabling:

* Git branch + dirty status  
* Exit‑code badges  
* Execution‑time measurement for long commands

> **Font reminder** – set Windows Terminal (or Alacritty/WezTerm) to `MesloLGS NF` for symbol support.

---

## 4. Nerd‑Fonts  

All four MesloLGS Nerd‑Font variants (Regular, Bold, Italic, BoldItalic) are fetched to  
`~/.local/share/fonts` and the cache refreshed with `fc-cache -fv`.

---

## 5. Plugins Installed  

| Plugin | Benefit |
|--------|---------|
| `zsh-autosuggestions` | Greyed‑out suggestion of the rest of the command. |
| `zsh-autocomplete` | FZF‑style completion menu. |
| `history-substring-search` | ↑/↓ filtering through history matching what you typed. |
| `zsh-syntax-highlighting` | Colours valid vs invalid command parts. |

The script edits `~/.zshrc` to enable these plus the theme.

---

## 6. Miniforge (Conda/Mamba)  

* **Detection** – if `~/miniforge3` already exists, you are offered an interactive update.  
* **Fresh install** – architecture‑specific installer (x86_64 or aarch64) is downloaded, run non‑interactively, and then `conda init zsh` is called.

By default Miniforge carries **Mamba**, a C++ re‑implementation of the conda solver that resolves complex ML dependency trees in seconds rather than minutes.

---

## 7. Idempotency & Safety  

Every destructive operation is wrapped in checks: existing directories trigger prompts rather than overwrites.  
You can run the script multiple times to pick up newer plugin versions or update Miniforge without harm.

---

## Result  

Open a **new** terminal and you will be greeted by the Powerlevel10k configuration wizard if you have not configured it before—answer the questions or accept the defaults.  
You now have:

* A colourful, information‑dense prompt.  
* Fast fuzzy completions.  
* Mamba‑powered Python env management tailored for AI work.

*(End of document)*