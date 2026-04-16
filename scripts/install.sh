#!/bin/bash
set -e

echo "🐦 SuperPicky Installer"
echo "========================"

INSTALL_DIR="$HOME/Applications/SuperPicky"
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy app
echo "📦 Installing SuperPicky.app..."
cp -R "$SCRIPT_DIR/SuperPicky.app" "$INSTALL_DIR/"

echo ""
echo "✅ SuperPicky installed to $INSTALL_DIR"
echo ""
echo "To run:"
echo "  open $INSTALL_DIR/SuperPicky.app"
echo ""
echo "Note: On first launch the app will download CoreML models (~350 MB)."
echo "      Network connectivity is required for this one-time download."
