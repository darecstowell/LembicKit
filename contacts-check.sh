#!/bin/zsh
# One-shot check that Contacts handle-to-name resolution works (the address-book
# entitlement plus the CNContactStore path). Run it from Apple's Terminal.app, or
# any terminal that has the address-book entitlement. Hardened-runtime terminals
# without it are denied by tccd before any permission prompt can appear.
#
# Pass a chat.db path, or it defaults to your live Messages database.
set -e
cd "$(dirname "$0")"
swift build >/dev/null
DB="${1:-$HOME/Library/Messages/chat.db}"
./.build/debug/lembic-cli conversations "$DB" --contacts
