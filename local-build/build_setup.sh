#!/usr/bin/env bash
# build_zmk_locally.sh - Build ZMK firmware locally based on the matrix created from build.yaml

set -euo pipefail
start_time=$(date +%s)

# --- CONFIGURABLE SETTINGS ---
ENABLE_USB_LOGGING="false"                         # Set to "true" to enable USB logging
REPO_ROOT="${REPO_ROOT:-$PWD}"                     # path to original repo root
SHIELD_PATH="${SHIELD_PATH:-boards/shields}"       # where shield folders live relative to repo root
CONFIG_PATH="${CONFIG_PATH:-config}"               # where configs live
FALLBACK_BINARY="${FALLBACK_BINARY:-bin}"          # fallback firmware extension

# --- ZMK WORKSPACE ---
echo "🛠️  Setting up ZMK workspace..."

# Only init if not already initialized (i.e., .west folder doesn't exist)
if [ ! -d ".west" ]; then
    echo "Initializing west workspace..."
    west init -l config
fi

# # Mark ZMK source as a safe Git directory
# git config --global --add safe.directory /workspaces/zmk/zephyr
# git config --global --add safe.directory /workspaces/zmk/zmk

# Update to fetch all modules and dependencies
echo "🛠️  Updating west modules..."
west update > /dev/null 2>&1

# Set environment variables in the current shell
echo "🛠️  Setting Zephyr build environment..."
west zephyr-export > /dev/null 2>&1

# --- Set location for local binaries ---
LOCAL_BIN_DIR="$REPO_ROOT/local-build"
mkdir -p "$LOCAL_BIN_DIR"

# Add LOCAL_BIN_DIR to PATH if not already there
if [[ ":$PATH:" != *":$LOCAL_BIN_DIR:"* ]]; then
  PATH="$LOCAL_BIN_DIR:$PATH"
fi

# --- Install yq (downloads Mike Farah's Go-based yq) for YAML processing ---
if [ ! -f "$LOCAL_BIN_DIR/yq" ]; then
  echo "🛠️  Installing yq..."
  curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o "$LOCAL_BIN_DIR/yq"
  chown 777 "$LOCAL_BIN_DIR/yq"
  chmod +x "$LOCAL_BIN_DIR/yq"
else
  echo "🛠️  yq already installed."
fi

# --- Install jq (downloads jq binary) for JSON processing ---
if [ ! -f "$LOCAL_BIN_DIR/jq" ]; then
  echo "🛠️  Installing jq..."
  curl -fsSL https://github.com/stedolan/jq/releases/latest/download/jq-linux64 -o "$LOCAL_BIN_DIR/jq"
  chown 777 "$LOCAL_BIN_DIR/jq"
  chmod +x "$LOCAL_BIN_DIR/jq"
else
  echo "🛠️  jq already installed."
fi

# Set permissions so users can delete them in their own environment
echo "🛠️  Setting permissions on ZMK resources..."
chmod -R 777 .west zmk zephyr modules zmk-pmw3610-driver

# # Debug: confirm checkout
# echo "🛠️  West workspace ready. Project structure:"
# west list

# Parse build entries from build.yaml
mapfile -t build_entries < <(
  yq eval -o=json '.include // []' "$REPO_ROOT/build.yaml" | jq -c '.[]'
)

if [ ${#build_entries[@]} -eq 0 ]; then
  echo "⚠️ No build entries defined in build.yaml"
  exit 0
fi

# # Print all discovered build entries (for debug)
# echo "🔍 Parsed build entries from build.yaml:"
# for entry in "${build_entries[@]}"; do
#   echo "  $entry"
# done


# --- SANDBOX SETUP FUNCTION ---
setup_sandbox() {
  local shield="$1"

  # Copy in zmk base repo to the sandbox
  echo "🏖️  Setting up sandbox for shield: $shield..."
  SANDBOX_ROOT=$(mktemp -d)
  printf "⚙️  %s\n" "→ Copying files into sandbox.."

  # Copy in all files from the original repo to the sandbox for modules and imports
  cp -r "$REPO_ROOT/." "$SANDBOX_ROOT/"

  # Copy all configs to the sandboxed zmk app path
  # This will allow #include directives to be the same as they are in the repo
  printf "⚙️  %s\n" "→ Installing configs ($shield) into ZMK module"
  NEW_CONFIG_PATH="$SANDBOX_ROOT/zmk/app/config"
  rm -rf "$NEW_CONFIG_PATH"
  mkdir -p "$NEW_CONFIG_PATH"
  cp -r "$SANDBOX_ROOT/$CONFIG_PATH"/* "$NEW_CONFIG_PATH/"

  # Copy shields to the sandboxed zmk app path
  printf "⚙️  %s\n" "→ Installing custom shield ($shield) into ZMK module"
  ZMK_SHIELDS_DIR="$SANDBOX_ROOT/zmk/app/boards/shields"
  mkdir -p "$ZMK_SHIELDS_DIR"

  if [[ "$shield" == "settings_reset" ]]; then
    printf "   ↳ Using upstream settings_reset shield\n"

    # Patch the mock matrix with a single entry so GCC stops warning about zero length.
    reset_overlay="$SANDBOX_ROOT/zmk/app/boards/shields/settings_reset/settings_reset.overlay"
    sed -i 's/rows = <0>;/rows = <1>;/' "$reset_overlay"
    sed -i 's/events = <>;/events = <0>;/' "$reset_overlay"
  else
    cp -a "$SANDBOX_ROOT/$SHIELD_PATH/." "$ZMK_SHIELDS_DIR/"
  fi

  cd "$SANDBOX_ROOT"
}


# --- BUILD LOOP FOR EACH SHIELD x KEYMAP ---
echo "🚦 Starting build loop based on build.yaml entries"

# Clear previous firmwares
rm -rf /workspaces/zmk/firmwares/*


# --- BUILD FIRMWARE FUNCTION ---
build_firmware() {
  local shield="$1"
  local target="$2"
  local  board="$3"
  local keymap="${4:-}"   # optional

  # Create a fresh build directory for each build
  BUILD_DIR=$(mktemp -d)
  printf "🗂  %s\n" "→ Build dir: $BUILD_DIR"
  if [[ -n "$keymap" ]]; then
    printf "🛡  %s\n" "→ Building: shield=$shield target=$target keymap=$keymap board=$board"
  else
    printf "🛡  %s\n" "→ Building: shield=$shield target=$target board=$board"
  fi

  # Add any extra snippets if specified in build.yaml (mostly used for ZMK Studio)
  EXTRA_SNIPPET=""
  if [[ -n "$entry_snippet" ]]; then
    EXTRA_SNIPPET="-S $entry_snippet"
  fi

  # Enable USB logging if specified at the top of this script
  USB_LOGGING_SNIPPET=""
  if [[ "$ENABLE_USB_LOGGING" == "true" ]]; then
    USB_LOGGING_SNIPPET="-S zmk-usb-logging"
  fi

  # Load extra modules only when the shield references the PMW3610 driver
  if grep -q "charybdis_pmw3610" "$ZMK_SHIELDS_DIR/$shield/"*.overlay 2>/dev/null; then
    ZMK_LOAD_ARG="-DZMK_EXTRA_MODULES=$SANDBOX_ROOT/zmk-pmw3610-driver"
  else
    ZMK_LOAD_ARG=""
  fi

  # Run the build
  west build --pristine -s "$SANDBOX_ROOT/zmk/app" \
    -d "$BUILD_DIR" \
    -b "$board" \
    $EXTRA_SNIPPET \
    $USB_LOGGING_SNIPPET \
    -- \
      -DZMK_CONFIG="$NEW_CONFIG_PATH" \
      -DSHIELD="$target" \
      $ZMK_LOAD_ARG \

  echo ""

  # Determine the artifact type to copy (prefer .uf2, fallback to specified binary type)
  if [ -f "$BUILD_DIR/zephyr/zmk.uf2" ]; then
    ARTIFACT_SRC="$BUILD_DIR/zephyr/zmk.uf2"
    ARTIFACT_EXT="uf2"
  elif [ -f "$BUILD_DIR/zephyr/zmk.${FALLBACK_BINARY}" ]; then
    ARTIFACT_SRC="$BUILD_DIR/zephyr/zmk.${FALLBACK_BINARY}"
    ARTIFACT_EXT="$FALLBACK_BINARY"
  else
    echo "❌ No firmware artifact found for ${target}-${keymap}-${board}"
    return 1
  fi

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
  FIRMWARES_FORMAT_DIR="/workspaces/zmk/firmwares/${format_dir}"
  # If no keymap, fall back to shield name + "_no_keymap"
  dir_suffix="${keymap:-${shield}_no_keymap}"
  FIRMWARES_DIR="${FIRMWARES_FORMAT_DIR}/${dir_suffix}"

  mkdir -p "$FIRMWARES_DIR"
  chmod 777 "$FIRMWARES_FORMAT_DIR" "$FIRMWARES_DIR"

  DEST="$FIRMWARES_DIR/${target}.${ARTIFACT_EXT}"
  echo "Publishing $ARTIFACT_SRC → $DEST"
  cp "$ARTIFACT_SRC" "$DEST"
  chmod 666 "$DEST"
}

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
    printf "⚠️  No shields listed for entry: $entry_json"
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

  # Loop through each board, shield, and keymap combination matrix
  for entry_board in "${entry_boards[@]}"; do
    for shield in "${entry_shields[@]}"; do
      setup_sandbox "$shield"
      cd "$SANDBOX_ROOT/zmk"

      # Discover all overlay targets in the current shield directory
      mapfile -t shield_targets < <(
        find "$ZMK_SHIELDS_DIR/$shield" -maxdepth 1 -type f -name "*.overlay" -exec basename {} .overlay \;
      )
      if [ ${#shield_targets[@]} -eq 0 ]; then
        echo "⚠️  No overlay targets found in $shield"
        rm -rf "$SANDBOX_ROOT"
        continue
      fi

      for target in "${shield_targets[@]}"; do
        if [[ "$shield" == "settings_reset" ]]; then
          # Build once without a keymap for settings_reset shield
          build_firmware "$shield" "$target" "$entry_board"
        else
          if [ ${#entry_keymaps[@]} -eq 0 ]; then
            printf "⚠️  No keymap specified for entry: $entry_json"
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
end_time=$(date +%s)
elapsed=$(( end_time - start_time ))
minutes=$(( elapsed / 60 ))
seconds=$(( elapsed % 60 ))
echo "🏁 Ran for ${minutes}m ${seconds}s and finished @ $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
