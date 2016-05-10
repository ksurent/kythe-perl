#!/bin/bash -e

# sligtly modified version of kythe-browse.sh from
# https://www.kythe.io/2015/07/13/flow/

set -o pipefail

BROWSE_PORT="${BROWSE_PORT:-8080}"
BROWSE_HOST="${BROWSE_HOST:localhost}"

rm -f -- graphstore/* tables/*
mkdir -p graphstore tables

entrystream --read_json \
  | dedup_stream \
  | write_entries -graphstore graphstore

write_tables -graphstore graphstore -out=tables

http_server -serving_table tables \
  -public_resources="${HOME}/kythe/kythe/web/ui" \
  -listen="${BROWSE_HOST}:${BROWSE_PORT}"
