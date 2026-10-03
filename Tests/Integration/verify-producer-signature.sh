#!/bin/bash
# OS-backed authorization checks against the built, signed host. No camera access.
# Run after a signed build: ./Tests/Integration/verify-producer-signature.sh /path/AppleCam.app
set -euo pipefail
app=${1:?Provide the signed AppleCam app path}
valid='anchor apple generic and identifier "com.vanguardsignals.AppleCam" and certificate leaf[subject.OU] = "M8QBZK948M"'
wrong_identifier='anchor apple generic and identifier "com.vanguardsignals.NotAppleCam" and certificate leaf[subject.OU] = "M8QBZK948M"'
wrong_team='anchor apple generic and identifier "com.vanguardsignals.AppleCam" and certificate leaf[subject.OU] = "ZZZZZZZZZZ"'
/usr/bin/codesign --verify --strict -R "=$valid" "$app"
if /usr/bin/codesign --verify --strict -R "=$wrong_identifier" "$app" 2>/dev/null; then
    echo 'FAIL: incorrect identifier accepted'; exit 1
fi
if /usr/bin/codesign --verify --strict -R "=$wrong_team" "$app" 2>/dev/null; then
    echo 'FAIL: incorrect team accepted'; exit 1
fi
if /usr/bin/codesign --verify --strict -R "=$valid" /usr/bin/true 2>/dev/null; then
    echo 'FAIL: unrelated signed program accepted'; exit 1
fi
echo 'PASS: signed host accepted; wrong identifier, wrong team and unrelated signed program rejected.'
