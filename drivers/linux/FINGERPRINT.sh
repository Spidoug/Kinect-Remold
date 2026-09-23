#!/usr/bin/env bash
# Prints the content fingerprint of the Linux driver/runtime source tree
# (drivers/linux). The build stores it in binaries/linux/drivers/BUILD-FINGERPRINT;
# the launcher and INSTALL.sh compare it so a runtime built from another source
# state is rebuilt by the launcher or refused by the offline installer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
