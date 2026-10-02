old_sync_all() {
  for target in "$@"; do
    old_sync_one "$target"
  done
}

old_sync_one() {
  rsync -a "$1" /tmp/old-sync-target/ || old-sync --retry "$1"
}
