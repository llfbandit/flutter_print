#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Generating Pigeon messages..."
dart run pigeon --input pigeon/messages.dart

echo "Copying Messages.swift to macOS..."
cp flutter_print/ios/flutter_print/Sources/flutter_print/Messages.swift \
   flutter_print/macos/flutter_print/Sources/flutter_print/Messages.swift

echo "Done."
