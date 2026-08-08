#!/bin/bash
# install.sh — Install meta-orchestrator skill to ~/.claude/skills/
# Cross-platform compatible. Idempotent.
#
# Usage:
#   ./install.sh                 # install to ~/.claude/skills/meta-orchestrator
#   ./install.sh --target DIR    # install to a custom directory
#   ./install.sh --uninstall     # remove the installed copy
#
# Works on Linux, macOS, and Windows (Git Bash / WSL).

set -e

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${HOME}/.claude/skills/meta-orchestrator"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_DIR="$2"
      shift 2
      ;;
    --uninstall)
      if [ -d "$TARGET_DIR" ]; then
        rm -rf "$TARGET_DIR"
        echo "✓ Removed $TARGET_DIR"
      else
        echo "Not installed at $TARGET_DIR"
      fi
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      echo "Usage: $0 [--target DIR] [--uninstall]"
      exit 1
      ;;
  esac
done

# Detect OS for path display
case "$OSTYPE" in
  linux*)   OS_DISPLAY="Linux" ;;
  darwin*)  OS_DISPLAY="macOS" ;;
  msys*|cygwin*|win32*) OS_DISPLAY="Windows" ;;
  *)        OS_DISPLAY="Unknown ($OSTYPE)" ;;
esac

echo "Installing meta-orchestrator skill"
echo "  Source: $SOURCE_DIR"
echo "  Target: $TARGET_DIR"
echo "  OS:     $OS_DISPLAY"

# Check source
if [ ! -f "$SOURCE_DIR/SKILL.md" ]; then
  echo "✗ ERROR: SKILL.md not found in $SOURCE_DIR"
  echo "  Run this script from the skill's source directory."
  exit 1
fi

# Check dependencies
if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  echo "✗ ERROR: Python not found. Install Python 3.8+ first."
  exit 1
fi

PYTHON_CMD=$(command -v python3 || command -v python)
echo "  Python: $PYTHON_CMD"

# Check PyYAML
if ! $PYTHON_CMD -c "import yaml" 2>/dev/null; then
  echo "⚠ PyYAML not installed. Installing..."
  $PYTHON_CMD -m pip install pyyaml || {
    echo "✗ Failed to install PyYAML. Run: $PYTHON_CMD -m pip install pyyaml"
    exit 1
  }
fi

# Create target directory
mkdir -p "$TARGET_DIR"

# Copy skill files (preserving structure)
# Don't copy dynamic files that should be generated on first run
for item in SKILL.md hooks scripts workflows; do
  if [ -e "$SOURCE_DIR/$item" ]; then
    cp -r "$SOURCE_DIR/$item" "$TARGET_DIR/"
  fi
done

# Clean any dynamic files from the install (should be generated fresh)
rm -f "$TARGET_DIR/scripts/pattern-memory.yaml"
rm -f "$TARGET_DIR/.codex-turn-end-trigger"

echo ""
echo "✓ Installed to $TARGET_DIR"
echo ""
echo "Verify by listing:"
echo "  ls $TARGET_DIR"
echo ""
echo "To uninstall: $0 --uninstall"