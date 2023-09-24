#!/bin/sh

TARGET="/usr/bin/pacbro"

# a few basic sanity checks in order not to remove a wrong script
file -bi "$TARGET" | grep -q 'perl;' && # must be a Perl script
	grep -q 'tmux' "$TARGET" && # must have certain keywords
	grep -q 'pacman' "$TARGET" &&
	sudo rm -f "$TARGET" &&
	echo "'pacbro' was uninstalled"
