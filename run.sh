#!/usr/bin/env bash
set -euo pipefail

echo "=== Assembling bootstrap.sh ==="
bash scripts/assemble.sh > bootstrap.sh
bash -n bootstrap.sh
echo "  Syntax OK"

docker build -f Dockerfile -t spinup-test .

echo ""
echo "=== Launching test container ==="
echo "Run:  ./bootstrap.sh         (base tier)"
echo "Run:  ./bootstrap.sh --dev   (dev tier)"
echo ""

docker run --rm -it \
  --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  spinup-test
