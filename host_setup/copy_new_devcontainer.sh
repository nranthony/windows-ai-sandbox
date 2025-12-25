#!/bin/bash

# ==============================================================================
# Dev Container Copy Script (v3.0 - Simplified)
#
# Description:
#   This script automates setting up a project with a standardized Dev Container
#   configuration from a template. It copies the necessary files, sets
#   permissions, and safely modifies the `devcontainer.json` file to
#   configure the display name and environment file.
#
#   Version 3.0 changes:
#   - Removed --name flag (VS Code auto-generates unique container names)
#   - Added file validation before copy
#   - Added comprehensive post-setup instructions
#   - Improved error handling
#
# Dependencies:
#   - jq: This script requires the 'jq' command-line JSON processor.
#     On Debian/Ubuntu, install with: sudo apt-get install jq
#     On macOS, install with: brew install jq
#
# Author: Gemini (original), Claude Code (v3.0 updates)
# Date: 2025-10-13
# ==============================================================================

# Exit immediately if a command fails, and treat pipeline failures as a script failure.
set -e
set -o pipefail

# --- Configuration ---
# An array of script names within the .devcontainer folder to make executable.
readonly SCRIPTS_TO_MAKE_EXECUTABLE=(
    "entrypoint.sh"
    "set-git-global.sh"
    "ohmyzsh-container-setup.sh"
)

# --- Functions ---

# Displays the script's usage instructions and exits.
usage() {
    cat <<EOF
Usage: $0 -s <source_repo_path> -t <target_repo_path> -d <display_name> [-e]

Automates the setup of a .devcontainer configuration from a template.

Options:
  -s    Path to the template repository containing the .devcontainer directory.
  -t    Path to the target repository where the .devcontainer will be copied.
  -d    The Dev Container's display name in VS Code (e.g., 'My Project').
  -e    (Optional) Flag to enable the '--env-file' argument (recommended).
  -h    Display this help message.

Example:
  $0 -s ~/templates/dev-main -t ~/projects/new-app -d "New App" -e

Note: VS Code auto-generates unique container names, so --name flag is not needed.
EOF
}

# Checks for required command-line tools.
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo "Error: 'jq' is not installed but is required. Please install it to continue." >&2
        echo "-> On Debian/Ubuntu: sudo apt-get install jq" >&2
        exit 1
    fi
}

# --- Main Logic ---
main() {
    # Initialize variables to their default state.
    local source_repo=""
    local target_repo=""
    local display_name=""
    local use_env_file=false

    # Parse command-line options.
    while getopts "s:t:d:eh" opt; do
        case ${opt} in
            s) source_repo=${OPTARG} ;;
            t) target_repo=${OPTARG} ;;
            d) display_name=${OPTARG} ;;
            e) use_env_file=true ;;
            h)
                usage
                exit 0
                ;;
            \?)
                echo "Invalid option: -${OPTARG}" >&2
                usage
                exit 1
                ;;
        esac
    done

    # Validate that all mandatory arguments have been provided.
    if [[ -z "$source_repo" || -z "$target_repo" || -z "$display_name" ]]; then
        echo "Error: Missing one or more required arguments." >&2
        usage
        exit 1
    fi

    # Run dependency checks before proceeding.
    check_dependencies

    # --- Step 1: Validate Paths and Define Variables ---
    echo "--> Validating paths..."
    local source_devcontainer_path="${source_repo}/.devcontainer"
    local target_devcontainer_path="${target_repo}/.devcontainer"

    if [ ! -d "$source_devcontainer_path" ]; then
        echo "Error: Source .devcontainer directory not found at '${source_devcontainer_path}'" >&2
        exit 1
    fi
    if [ ! -d "$target_repo" ]; then
        echo "Error: Target repository directory not found at '${target_repo}'" >&2
        exit 1
    fi
    echo "    Source and target paths are valid."

    # --- Step 1b: Validate Required Files ---
    echo "--> Validating required files..."
    local required_files=("Dockerfile" "devcontainer.json" ".p10k.zsh" ".zshrc" "entrypoint.sh" "set-git-global.sh" "ohmyzsh-container-setup.sh")
    for file in "${required_files[@]}"; do
        if [ ! -f "${source_devcontainer_path}/${file}" ]; then
            echo "Error: Required file '${file}' not found in source .devcontainer!" >&2
            exit 1
        fi
    done
    echo "    All required files present."

    # --- Step 2: Copy and Set Permissions ---
    echo "--> Copying .devcontainer directory and setting permissions..."
    cp -r "$source_devcontainer_path" "$target_repo/"

    for script in "${SCRIPTS_TO_MAKE_EXECUTABLE[@]}"; do
        local script_path="${target_devcontainer_path}/${script}"
        if [ -f "$script_path" ]; then
            chmod +x "$script_path"
            echo "    Set +x on ${script}"
        fi
    done
    echo "    Copy and permission setup complete."

    # --- Step 2b: Copy .env file if present and -e flag is set ---
    if [ "$use_env_file" = true ]; then
        local source_env_path="${source_repo}/.env"
        if [ -f "$source_env_path" ]; then
            echo "--> Copying .env file from source repository..."
            cp "$source_env_path" "$target_repo/.env"
            echo "    .env file copied successfully."
        fi
    fi

    # --- Step 3: Modify devcontainer.json ---
    local devcontainer_json_path="${target_devcontainer_path}/devcontainer.json"
    if [ ! -f "$devcontainer_json_path" ]; then
        echo "Error: devcontainer.json not found in the target directory!" >&2
        exit 1
    fi

    echo "--> Modifying devcontainer.json..."

    # WARNING: The following `sed` command is a best-effort attempt to strip C-style
    # comments (//) from the JSON file. It is NOT a full parser and can break if
    # '//' appears inside a string literal (e.g., a URL).
    # For maximum safety, provide a template devcontainer.json file without comments.
    local json_content_no_comments
    json_content_no_comments=$(cat "$devcontainer_json_path" | sed -e '/^[[:space:]]*\/\//d' -e 's/[[:space:]]\/\/.*//')

    # Atomically update the JSON content using a temporary variable and a pipe of jq commands.
    local temp_json
    
    # Set the top-level display name
    echo "    Setting Dev Container display name to '${display_name}'."
    temp_json=$(echo "$json_content_no_comments" | jq --arg dname "$display_name" '.name = $dname')

    # Modify the runArgs array
    temp_json=$(echo "$temp_json" | \
        # 1. Ensure .runArgs exists and is an array; create it if null.
        jq '.runArgs |= if . == null then [] else . end' | \
        # 2. Unconditionally remove any existing '--env-file' flag and its subsequent value.
        jq 'if (.runArgs | index("--env-file")) then del(.runArgs[(.runArgs | index("--env-file")) : ((.runArgs | index("--env-file")) + 2)]) else . end'
    )

    # Add --env-file if requested
    if [ "$use_env_file" = true ]; then
        echo "    Enabling --env-file argument."
        temp_json=$(echo "$temp_json" | jq '.runArgs += ["--env-file", "${localWorkspaceFolder}/.env"]')
    fi

    # Write the final, modified JSON back to the file.
    echo "$temp_json" > "$devcontainer_json_path"

    echo "    devcontainer.json has been successfully configured."
    echo ""
    echo "✅ Setup complete! Your new project at '${target_repo}' is ready."
    echo ""

    # Display important post-setup reminders
    if [ "$use_env_file" = true ]; then
        echo "⚠️  IMPORTANT: Create a .env file in ${target_repo} with:"
        echo "    GIT_NAME=\"your-name\""
        echo "    GIT_EMAIL=\"your-email@example.com\""
        echo ""
    fi

    echo "📋 Next steps:"
    echo "    1. cd ${target_repo}"
    echo "    2. Create .env file (if using -e flag)"
    echo "    3. code . (from inside WSL)"
    echo "    4. Ctrl+Shift+P → 'Dev Containers: Rebuild and Reopen in Container'"
    echo ""
    echo "📚 See .devcontainer/NON-ROOT-SETUP.md for troubleshooting"
    echo ""
    echo "ℹ️  Requirements:"
    echo "    - CUDA 12.6.3 compatible NVIDIA driver (≥530.30)"
    echo "    - Docker network 'ai-sandbox' must exist"
    echo "    - Rootless Docker socket at /run/user/1000/docker.sock"
}

# This standard guard ensures the main function is called only when the script is executed directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
