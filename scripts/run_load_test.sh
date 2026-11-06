#!/bin/sh
# Runs scripts/load_test.exs with production settings against its own database, in
# the toolchain container. Arguments are passed on, for example:
#
#   scripts/run_load_test.sh --sockets 1000 --messages 5 --interval 1000
set -e
cd "$(dirname "$0")/.."

exec docker compose run --rm -T \
  -e MIX_ENV=prod \
  -e PHX_SERVER=true \
  -e PHX_HOST=localhost \
  -e POOL_SIZE="${POOL_SIZE:-30}" \
  -e SECRET_KEY_BASE=load-test-only-load-test-only-load-test-only-load-test-only-load-test \
  -e DATABASE_URL=ecto://postgres:postgres@db/chat_server_load \
  web sh -c 'mix local.hex --force --if-missing >/dev/null &&
             mix local.rebar --force --if-missing >/dev/null &&
             mix deps.get --only prod >/dev/null &&
             mix ecto.create --quiet &&
             mix ecto.migrate --quiet &&
             exec mix run scripts/load_test.exs "$@"' -- "$@"
