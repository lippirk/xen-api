#!/bin/bash
set -e

DATE=$(date "+%Y-%m-%d")
# shellcheck disable=SC2001
XAPI_VERSION=$(echo "$XAPI_VERSION" | sed "s/^v//g")

printf "let date = \"%s\"\n\n" "$DATE"
printf "let version = \"%s\"\n" "$XAPI_VERSION"
