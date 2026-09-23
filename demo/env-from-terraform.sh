#!/usr/bin/env bash
# Print the values the other scripts in this directory need, read from
# Terraform rather than retyped, so they cannot drift from what was applied.
#
#   eval "$(./env-from-terraform.sh)"
#
# ~/.zsp-poc.env carries the credentials and endpoints; this carries the names
# of the things Terraform created.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

terraform -chdir="${here}/../terraform" output -json demo_env \
  | jq -r 'to_entries[] | "export \(.key)=\(.value | @sh)"'
