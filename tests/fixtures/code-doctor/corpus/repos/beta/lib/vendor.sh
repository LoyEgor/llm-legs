vendor_fetch() {
  curl -fsS "https://example.invalid/vendor" -o /tmp/beta-vendor.json
  echo fetched
}

vendor_fetch
