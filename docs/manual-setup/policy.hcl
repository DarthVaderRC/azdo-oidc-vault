# Allow reading dev secrets
path "secret/data/dev/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/dev/*" {
  capabilities = ["list"]
}