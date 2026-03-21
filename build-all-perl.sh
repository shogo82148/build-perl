#!/bin/bash

set -uexo pipefail

ALL_PERL=$(jq -c . < versions.json)
gh workflow run build.yaml -f perl-versions="$ALL_PERL"
