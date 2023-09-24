#!/bin/sh

DIR="$(dirname "$(realpath "$0")")"
TARGET="/usr/bin/pacbro"
sudo install -m 0755 "$DIR/pacbro.pl" "$TARGET"

[ -x "$TARGET" ] &&
	printf "'pacbro' is installed as '$TARGET'.\nRun 'uninstall.sh' to uninstall\nRun 'pacbro -h' for details.\n"
