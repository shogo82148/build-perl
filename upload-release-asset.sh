#!/bin/bash

# upload files to a GitHub release.
# usage: upload-release-asset.sh TAG FILE...
#
# gh may report an error even when the upload succeeded (e.g. the response was lost).
# In that case, keep the uploaded asset if its digest matches the local file,
# and replace it with --clobber only when it doesn't.

set -euo pipefail

TAG=$1
shift

sha256() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

uploaded_digest() {
    gh release view "$TAG" --json assets \
        --jq '.assets[] | select(.state == "uploaded") | "\(.name)\t\(.digest)"' |
        awk -F'\t' -v name="$1" '$1 == name { print $2 }'
}

for FILE in "$@"; do
    NAME=$(basename "$FILE")
    if gh release upload "$TAG" "$FILE"; then
        continue
    fi

    EXPECTED="sha256:$(sha256 "$FILE")"
    ACTUAL=$(uploaded_digest "$NAME")
    if [[ "$ACTUAL" == "$EXPECTED" ]]; then
        echo "$NAME is already uploaded with the same digest ($EXPECTED)."
        continue
    fi

    echo "replacing $NAME (uploaded: ${ACTUAL:-none}, local: $EXPECTED)."
    gh release upload --clobber "$TAG" "$FILE"
done
