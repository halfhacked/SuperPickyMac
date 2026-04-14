#!/bin/bash
set -e

echo "🐦 SuperPicky v0.0.1 Installer"
echo "================================"

INSTALL_DIR="$HOME/Applications/SuperPicky"
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Copy app
echo "📦 Installing SuperPicky.app..."
cp -R "$SCRIPT_DIR/SuperPicky.app" "$INSTALL_DIR/"

# 2. Copy Python server
echo "🐍 Installing Python server..."
cp -R "$SCRIPT_DIR/python-server" "$INSTALL_DIR/"

# 3. Create venv and install dependencies
echo "📥 Installing Python dependencies (this may take a few minutes)..."
cd "$INSTALL_DIR/python-server"
python3 -m venv .venv
source .venv/bin/activate
pip install --quiet -r requirements.txt
pip install --quiet birdpreen
deactivate

echo ""
echo "✅ SuperPicky installed to $INSTALL_DIR"
echo ""
echo "To run:"
echo "  1. Start the server:  cd $INSTALL_DIR/python-server && .venv/bin/python superpicky_server.py"
echo "  2. Open the app:      open $INSTALL_DIR/SuperPicky.app"
