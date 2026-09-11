#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
xcodebuild -quiet -project AIUsage.xcodeproj -scheme AIUsage \
  -configuration Release -derivedDataPath build build
open "$PWD/build/Build/Products/Release/AI Usage.app"
