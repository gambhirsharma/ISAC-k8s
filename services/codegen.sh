#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -m grpc_tools.protoc \
  -I=proto \
  --python_out=proto \
  --grpc_python_out=proto \
  proto/isac.proto
# fix imports for Python 3
sed -i 's/import isac_pb2/from . import isac_pb2/' proto/isac_pb2_grpc.py
