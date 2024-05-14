#!/bin/sh
# Installs all *.pl scripts in /usr/bin

srcdir="$(dirname "$(realpath "$0")")"
bindir="/usr/bin"

cd "$srcdir" || { echo "Dir $srcdir is inaccessible"; exit 1; }

ls -1 *.pl | ( while read pl_script; do
	[ -x "$pl_script" ] || continue;
	pl_basename="${pl_script%.*}"
	sudo install -p -m 0755 "$srcdir/$pl_script" "$bindir/$pl_basename"
	printf "Installed '$bindir/$pl_basename'\n"
done )

printf "Run 'uninstall.sh' to uninstall'\n"
