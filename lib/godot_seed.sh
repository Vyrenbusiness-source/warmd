# Godot import cache shared between worktrees. Every worktree has its own .godot/imported, so a texture another
# checkout already compressed (8192x4096 BPTC: minutes of CPU each) was compressed again in every worktree after
# each merge. godot_seed_imports copies a finished import from a donor checkout when it is the same import: the
# .import file is byte for byte the same and the donor's .md5 names the md5 of this checkout's source file.
# Godot then sees a valid cache and skips the file. Loaded on demand (hook before an --import, adapter before its own).

godot_seed_imports() { # project dir [donor dir...] -> REPLY = number of imports copied
  local dir="$1" d imp src dest name md5f want have n=0 line donors=()
  shift
  REPLY=0
  [ -f "$dir/project.godot" ] || return 0
  if [ $# -gt 0 ]; then donors=("$@")
  else
    while IFS= read -r line; do
      case "$line" in "worktree "*) d="${line#worktree }"; [ "$d" != "$dir" ] && [ -d "$d/.godot/imported" ] && donors+=("$d");; esac
    done < <(git -C "$dir" worktree list --porcelain 2>/dev/null)
  fi
  [ ${#donors[@]} -gt 0 ] || return 0
  mkdir -p "$dir/.godot/imported" || return 0
  while IFS= read -r imp; do
    dest=""
    while IFS= read -r line; do
      case "$line" in dest_files=*) dest="${line#*\"res://}"; dest="${dest%%\"*}"; break;; esac
    done < "$imp"
    [ -n "$dest" ] || continue
    [ -f "$dir/$dest" ] && continue                     # already imported here
    src="${imp%.import}"; [ -f "$src" ] || continue
    name="${dest##*/}"; md5f="${name##*-}"; md5f="${dest%/*}/${name%-*}-${md5f%%.*}.md5"   # x.webp-<hash>.bptc.ctex -> x.webp-<hash>.md5
    want=""
    for d in "${donors[@]}"; do
      [ -f "$d/$dest" ] && [ -f "$d/$md5f" ] || continue
      cmp -s "$imp" "$d/${imp#"$dir"/}" || continue     # other import settings: not the same import
      [ -n "$want" ] || { want="$(md5sum "$src" 2>/dev/null)"; want="${want%% *}"; }
      have=""
      while IFS= read -r line; do case "$line" in source_md5=*) have="${line#*\"}"; have="${have%\"*}";; esac; done < "$d/$md5f"
      [ -n "$want" ] && [ "$have" = "$want" ] || continue
      cp -f "$d/$dest" "$dir/$dest" && cp -f "$d/$md5f" "$dir/$md5f" && n=$((n + 1))
      break
    done
  done < <(find "$dir" -name '*.import' -not -path '*/.godot/*' -not -path '*/.git/*' 2>/dev/null)
  REPLY=$n
}
