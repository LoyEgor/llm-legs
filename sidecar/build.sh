#!/bin/bash
set -e
swiftc -O -target arm64-apple-macos14 "$(dirname "$0")/sidecar.swift" -o /tmp/sidecar-new
cp /tmp/sidecar-new ~/.local/bin/sidecar
