#!/bin/bash
# Build the .app bundle and launch it.
exec "$(cd "$(dirname "$0")" && pwd)/build_app.sh" --run
