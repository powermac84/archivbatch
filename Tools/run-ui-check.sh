#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/QASources .build/UICheck.app/Contents/MacOS .build/UICheck.app/Contents/Resources Reports
python3 - <<'PY'
import plistlib
s=open('Sources/App.swift').read().replace('@main\nstruct ArchivBatchApp', 'struct ArchivBatchApp')
s=s.replace('    func chooseInitialDestination() {', '    func chooseInitialDestination() {\n        if ProcessInfo.processInfo.environment["ARCHIVBATCH_UI_CHECK"] == "1" { return }')
open('.build/QASources/App.swift','w').write(s)
info=plistlib.load(open('Info.plist','rb'));info['CFBundleExecutable']='UICheck';info['CFBundleIdentifier']='local.archivbatch.uicheck';info['CFBundleName']='UICheck'
plistlib.dump(info,open('.build/UICheck.app/Contents/Info.plist','wb'))
PY
cp -R Resources/Localization .build/UICheck.app/Contents/Resources/
cp Vendor/7zz .build/UICheck.app/Contents/Resources/7zz
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .build/ModuleCache -target "$(uname -m)-apple-macosx14.0" -framework SwiftUI -framework AppKit .build/QASources/App.swift Sources/Localization.swift Sources/ArchiveEngine.swift Sources/PasswordStorage.swift Tools/UICheck.swift -o .build/UICheck.app/Contents/MacOS/UICheck
ARCHIVBATCH_UI_CHECK=1 .build/UICheck.app/Contents/MacOS/UICheck
