#!/usr/bin/env bash

set -x

MY_PATH="$(dirname -- "${BASH_SOURCE[0]}")"            # relative

cd -- "$MY_PATH"
python3 app.py&

