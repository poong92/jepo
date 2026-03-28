#!/bin/bash
LOG="$HOME/logs/claude-auto/keychain-fix.log"
mkdir -p "$HOME/logs/claude-auto"
echo "$(date): Starting keychain fix" >> "$LOG"
security set-keychain-settings "$HOME/Library/Keychains/login.keychain-db" >> "$LOG" 2>&1
echo "set-keychain-settings exit: $?" >> "$LOG"
security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >> "$LOG" 2>&1
echo "show-keychain-info exit: $?" >> "$LOG"
echo "$(date): Done" >> "$LOG"
