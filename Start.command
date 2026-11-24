#!/bin/sh
set -eu
cd "$(dirname "$0")"
bin/start
port=$(docker compose port web 3000 | awk -F: '{print $NF}')
open "http://localhost:$port"
