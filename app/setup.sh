#!/bin/bash
set -e
cd "$(dirname "$0")"

if ! command -v xcodegen &>/dev/null; then
    echo "Installing xcodegen..."
    brew install xcodegen
fi

echo "Generating JaSub.xcodeproj..."
xcodegen generate

echo ""
echo "Done. Open the project with:"
echo "  open JaSub.xcodeproj"
