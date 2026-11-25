#!/bin/sh
# Controlled routing-data update for the self-hosted BRouter container
# (technote.ROUTE-DRAW.md §10.9): downloads .rd5 segment files from the
# official segments4 set into the brouter_segments volume. Files land
# atomically (download to .part, rename on success), so a failed download
# can never leave the engine serving partially written data.
#
# The segments4 server serves a 5-DEGREE TILE GRID, not countries:
#   E<west>_<south>.rd5   e.g. E105_N15.rd5 covers 105-110E / 15-20N
# (https://brouter.de/brouter/segments4/ lists all ~1100 tiles.)
#
# Usage: ./brouter/download-segments.sh <tile> [<tile>...]
#   e.g. Thailand + Vietnam:
#   ./brouter/download-segments.sh E95_N5 E95_N10 E95_N15 E95_N20 \
#       E100_N5 E100_N10 E100_N15 E100_N20 E105_N10 E105_N15 E105_N20
#
# After a successful run, restart the engine so it reopens the files:
#   docker compose restart brouter   (dokploy: restart the brouter service)
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <tile> [<tile>...]   e.g. $0 E105_N15 E100_N10" >&2
  exit 1
fi

BASE_URL="${BRROUTER_SEGMENT_URL:-https://brouter.de/brouter/segments4}"

# The engine's volume: compose pins it to the literal name brouter_segments
# (docker-compose.yml `volumes.brouter_segments.name`), but tolerate a
# project-prefixed name for stacks created before the pin.
VOLUME="${BRROUTER_SEGMENTS_VOLUME:-$(docker volume ls -q | grep -E '(^|_)brouter_segments$' | head -n 1)}"
if [ -z "$VOLUME" ]; then
  echo "error: no brouter_segments volume found — start the stack once" >&2
  echo "       (docker compose up -d brouter) or set BRROUTER_SEGMENTS_VOLUME" >&2
  exit 1
fi
echo "==> volume: $VOLUME"

for tile in "$@"; do
  file="${tile}.rd5"
  echo "==> ${file}"
  docker run --rm \
    -v "${VOLUME}:/segments4" \
    -w /segments4 \
    alpine:3.20 \
    sh -c "
      set -e
      wget -q -O '${file}.part' '${BASE_URL}/${file}'
      mv '${file}.part' '${file}'
      ls -la '${file}'
    "
done

echo
echo "Done. Restart the engine so BRouter reopens the data:"
echo "  docker compose restart brouter"
