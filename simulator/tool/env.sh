#!/usr/bin/env bash
# Put the Avertis toolchain on PATH for this shell.
#
#   source tool/env.sh
#
# Nothing here is installed globally or written to your shell config, so this
# affects only the terminal you run it in. To make it permanent, copy these
# three exports into ~/.zshrc.

export PATH="$HOME/development/flutter/bin:$PATH"
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

# Flutter needs to be told where the SDK is, since it was not installed
# through Android Studio.
flutter config --android-sdk "$ANDROID_HOME" >/dev/null 2>&1 || true

echo "flutter  $(flutter --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
echo "adb      $(adb --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
echo "java     $($JAVA_HOME/bin/java -version 2>&1 | head -1 || echo 'NOT FOUND')"
echo "avds     $(emulator -list-avds 2>/dev/null | tr '\n' ' ')"
