#!/usr/bin/env bash
# build_zmk_locally.sh - Build ZMK firmware locally based on the matrix created from build.yaml

set -euo pipefail
START_TIME=$(date +%s)

# --- CONFIGURABLE SETTINGS ---
ENABLE_USB_LOGGING="false"                         # Set to "true" to enable USB logging
REPO_ROOT="${REPO_ROOT:-$PWD}"                     # path to original repo root
SHIELD_PATH="${SHIELD_PATH:-boards/shields}"       # where shield folders live relative to repo root
CONFIG_PATH="${CONFIG_PATH:-config}"               # where configs live
FALLBACK_BINARY="${FALLBACK_BINARY:-bin}"          # fallback firmware extension

# --- ZMK WORKSPACE ---
echo ""
echo "=== SETUP ZMK WORKSPACE ==="

# Only init if not already initialized (i.e., .west folder doesn't exist)
if [ ! -d ".west" ]; then
    echo "    Initializing west workspace..."
    west init -l config
fi

# Update to fetch all modules and dependencies
echo "Updating west modules..."
west update > /dev/null 2>&1

# Set environment variables in the current shell
echo "Preparing Zephyr build environment..."
west zephyr-export > /dev/null 2>&1

# Set location for local binaries
LOCAL_BIN_DIR="$REPO_ROOT/local-build"
mkdir -p "$LOCAL_BIN_DIR"

# Add LOCAL_BIN_DIR to PATH if not already there
if [[ ":$PATH:" != *":$LOCAL_BIN_DIR:"* ]]; then
  PATH="$LOCAL_BIN_DIR:$PATH"
fi

# Install yq (downloads Mike Farah's Go-based yq) for YAML processing
if [ ! -f "$LOCAL_BIN_DIR/yq" ]; then
  echo "Installing yq..."
  curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o "$LOCAL_BIN_DIR/yq"
  chmod +x "$LOCAL_BIN_DIR/yq"
else
  echo "yq already installed."
fi

# Install jq binary for JSON processing
if [ ! -f "$LOCAL_BIN_DIR/jq" ]; then
  echo "Installing jq..."
  curl -fsSL https://github.com/stedolan/jq/releases/latest/download/jq-linux64 -o "$LOCAL_BIN_DIR/jq"
  chmod +x "$LOCAL_BIN_DIR/jq"
else
  echo "jq already installed."
fi

# Set permissions so users can delete them in their own environment
echo "Setting permissions on ZMK resources..."
chmod -R 777 .west zmk zephyr modules zmk-pmw3610-driver

# # Debug: confirm checkout
# echo "    West workspace ready. Project structure:"
# west list

# Parse build entries from build.yaml
mapfile -t build_entries < <(
  yq eval -o=json '.include // []' "$REPO_ROOT/build.yaml" | jq -c '.[]'
)

if [ ${#build_entries[@]} -eq 0 ]; then
  echo "[WARN] No build entries defined in build.yaml"
  exit 0
fi


# --- SANDBOX SETUP FUNCTION ---
setup_sandbox() {
  local shield="$1"

  # Copy in zmk base repo to the sandbox
  echo ""
  echo "=== PREPARING SANDBOX ==="

  SANDBOX_ROOT=$(mktemp -d)
  echo "Copying repository into sandbox root"

  # Copy in all files from the original repo to the sandbox for modules and imports
  cp -r "$REPO_ROOT/." "$SANDBOX_ROOT/"

  # Copy all configs to the sandboxed zmk app path
  # This will allow #include directives to be the same as they are in the repo
  printf 'Installing configs\n'
  NEW_CONFIG_PATH="$SANDBOX_ROOT/zmk/app/config"
  rm -rf "$NEW_CONFIG_PATH"
  mkdir -p "$NEW_CONFIG_PATH"
  cp -r "$SANDBOX_ROOT/$CONFIG_PATH"/* "$NEW_CONFIG_PATH/"

  # Copy shields to the sandboxed zmk app path
  printf 'Installing custom shield (%s)\n' "$shield"
  ZMK_SHIELDS_DIR="$SANDBOX_ROOT/zmk/app/boards/shields"
  mkdir -p "$ZMK_SHIELDS_DIR"

  if [[ "$shield" == "settings_reset" ]]; then
    echo "Using upstream settings_reset shield"

    # Patch the settings_reset overlay mock kscan with a single entry so GCC stops warning about zero length.
    reset_overlay="$SANDBOX_ROOT/zmk/app/boards/shields/settings_reset/settings_reset.overlay"
    sed -i 's/rows = <0>;/rows = <1>;/' "$reset_overlay"
    sed -i 's/events = <>;/events = <0>;/' "$reset_overlay"
  else
    cp -a "$SANDBOX_ROOT/$SHIELD_PATH/." "$ZMK_SHIELDS_DIR/"
  fi

  cd "$SANDBOX_ROOT"
}

# Clear previous firmwares
rm -rf /workspaces/zmk/firmwares/*


# --- BUILD FIRMWARE FUNCTION ---
build_firmware() {
  local shield="$1"
  local target="$2"
  local board="$3"
  local keymap="${4:-}"

  local build_dir
  build_dir=$(mktemp -d)

  printf '\n=== BUILDING FIRMWARE ===\n'
  printf 'Build Context:\n'
  printf '  Shield : %s\n' "$shield"
  printf '  Target : %s\n' "$target"
  if [[ -n "$keymap" ]]; then
    printf '  Keymap : %s\n' "$keymap"
  fi
  printf '  Board  : %s\n' "$board"
  printf "\n"

  printf 'Build Directory:\n'
  printf '  %s\n' "$build_dir"

  # Add any extra snippets if specified in build.yaml (mostly used for ZMK Studio)
  local extra_snippet=""
  if [[ -n "$entry_snippet" ]]; then
    extra_snippet="-S $entry_snippet"
  fi

  # Enable USB logging if specified at the top of this script
  local usb_logging_snippet=""
  if [[ "$ENABLE_USB_LOGGING" == "true" ]]; then
    usb_logging_snippet="-S zmk-usb-logging"
  fi

  # Load PMW3610 module only when the shield references the PMW3610 driver
  local zmk_load_arg=""
  if grep -q "charybdis_pmw3610" "$ZMK_SHIELDS_DIR/$shield/"*.overlay 2>/dev/null; then
    zmk_load_arg="-DZMK_EXTRA_MODULES=$SANDBOX_ROOT/zmk-pmw3610-driver"
  fi

  # Run the build
  west build --pristine -s "$SANDBOX_ROOT/zmk/app" \
    -d "$build_dir" \
    -b "$board" \
    $extra_snippet \
    $usb_logging_snippet \
    -- \
      -DZMK_CONFIG="$NEW_CONFIG_PATH" \
      -DSHIELD="$target" \
      $zmk_load_arg \

  echo ""

  # Determine the artifact type to copy (prefer .uf2, fallback to specified binary type)
  local artifact_src=""
  local artifact_ext=""
  if [ -f "$build_dir/zephyr/zmk.uf2" ]; then
    artifact_src="$build_dir/zephyr/zmk.uf2"
    artifact_ext="uf2"
  elif [ -f "$build_dir/zephyr/zmk.${FALLBACK_BINARY}" ]; then
    artifact_src="$build_dir/zephyr/zmk.${FALLBACK_BINARY}"
    artifact_ext="$FALLBACK_BINARY"
  else
    echo "[WARN] No firmware artifact found for ${target}-${keymap}-${board}"
    return 1
  fi

  echo "=== PUBLISHING ARTIFACT & CLEANING UP ==="
  # Map the entry format to the correct directory name:
  # "bt"                - use charybdis_bt
  # "standard_dongle"   - use charybdis_dongle
  # "prospector_dongle" - use charybdis_dongle_prospector
  # anything else       - just use the original format name
  case "$entry_format" in
    bt)                format_dir="charybdis_bt" ;;
    standard_dongle)   format_dir="charybdis_dongle" ;;
    prospector_dongle) format_dir="charybdis_dongle_prospector" ;;
    *)                 format_dir="$entry_format" ;;
  esac

  # Publish the firmware artifact to the correct directory and set permissions
  local dest
  local firmwares_format_dir

  if [[ "$shield" == "settings_reset" ]]; then
    # Reset firmware goes at top-level (no folder)
    firmwares_dir="/workspaces/zmk/firmwares"
    mkdir -p "$firmwares_dir"
    chmod 777 "$firmwares_dir"
    dest="$firmwares_dir/settings_reset.${artifact_ext}"
  else
    # Normal builds are structured by format/keymap
    local firmwares_format_dir="/workspaces/zmk/firmwares/${format_dir}"
    local dir_suffix="${keymap:-${shield}_no_keymap}"
    firmwares_dir="${firmwares_format_dir}/${dir_suffix}"

    mkdir -p "$firmwares_dir"
    chmod 777 "$firmwares_format_dir" "$firmwares_dir"
    dest="$firmwares_dir/${target}.${artifact_ext}"
  fi
  
  printf 'Source: %s\n' "$artifact_src"
  printf 'Destination: %s\n' "$dest"
  cp "$artifact_src" "$dest"
  chmod 666 "$dest"
}

echo "Generating build matrix for each board, shield, and keymap combination in build.yaml..."
for entry_json in "${build_entries[@]}"; do
  # Pull format & snippet values out of the JSON
  entry_format=$(jq -r '.format // .name // "custom"' <<<"$entry_json")
  entry_snippet=$(jq -r '.snippet // ""' <<<"$entry_json")

  # Pull boards out of the JSON (handle single values or arrays) & store in entry_boards
  mapfile -t entry_boards < <(jq -r '
    if has("board") then
      if (.board | type) == "array" then .board[] else .board end
    else
      empty
    end
  ' <<<"$entry_json")

  if [ ${#entry_boards[@]} -eq 0 ]; then
    entry_boards=("nice_nano_v2")
  fi

  # Pull shields out of the JSON (handle single values or arrays) & store in entry_shields
  mapfile -t entry_shields < <(jq -r '
    if has("shield") then
      if (.shield | type) == "array" then .shield[] else .shield end
    elif has("shields") then
      if (.shields | type) == "array" then .shields[] else .shields end
    else
      empty
    end
  ' <<<"$entry_json")

  if [ ${#entry_shields[@]} -eq 0 ]; then
    printf '[WARN] No shields listed for entry: %s\n' "$entry_json"
    continue
  fi

  # Pull keymaps out of the JSON (handle single values or arrays) & store in entry_keymaps
  mapfile -t entry_keymaps < <(jq -r '
    if has("keymap") then
      if (.keymap | type) == "array" then .keymap[] else .keymap end
    elif has("keymaps") then
      if (.keymaps | type) == "array" then .keymaps[] else .keymaps end
    else
      empty
    end
  ' <<<"$entry_json")

  for entry_board in "${entry_boards[@]}"; do
    for shield in "${entry_shields[@]}"; do
      setup_sandbox "$shield"
      cd "$SANDBOX_ROOT/zmk"

      # Discover all overlay targets in the current shield directory
      mapfile -t shield_targets < <(
        find "$ZMK_SHIELDS_DIR/$shield" -maxdepth 1 -type f -name "*.overlay" -exec basename {} .overlay \;
      )
      if [ ${#shield_targets[@]} -eq 0 ]; then
        echo "[WARN] No overlay targets found in $shield"
        rm -rf "$SANDBOX_ROOT"
        continue
      fi

      for target in "${shield_targets[@]}"; do
        if [[ "$shield" == "settings_reset" ]]; then
          # Build once without a keymap for settings_reset shield
          build_firmware "$shield" "$target" "$entry_board"
        else
          if [ ${#entry_keymaps[@]} -eq 0 ]; then
            printf '[WARN] No keymap specified for entry: %s\n' "$entry_json"
            continue
          fi
          # Loop over every keymap
          for entry_keymap in "${entry_keymaps[@]}"; do
            keymap_path="$NEW_CONFIG_PATH/keymaps/${entry_keymap}.keymap"

            # Copy in the keymap to the config directory as charybdis.keymap
            cp "$keymap_path" "$NEW_CONFIG_PATH/charybdis.keymap"
            build_firmware "$shield" "$target" "$entry_board" "$entry_keymap"
          done
        fi
      done

      echo "Cleaning up sandbox..."
      rm -rf "$SANDBOX_ROOT"
      echo ""
    done
  done
done

# --- CALCULATE EXECUTION TIME ---
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECONDS=$(( ELAPSED % 60 ))
echo "=== BUILD COMPLETE ==="
echo "${MINUTES}m ${SECONDS}s @ $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
