#!/bin/sh

DIR="$(dirname "$(realpath "$0")")"
sudo install -m 0755 "$DIR/pacbro.pl" "/usr/bin/pacbro"
