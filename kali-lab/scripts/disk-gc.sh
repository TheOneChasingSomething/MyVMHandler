#!/usr/bin/env bash
# disk-gc.sh — report libvirt storage used by the lab and, interactively,
# reclaim space from old VMs and orphaned volumes.
#
# Safety model (never deletes blindly):
#   * A volume used as a backing file by any other volume (the golden image)
#     is ALWAYS protected and never offered for deletion.
#   * A volume attached to ANY still-defined domain is "in use"; a domain is
#     only offered for teardown when it is shut off.
#   * A detached "*-data.raw" is treated specially: by the DATA= design it may
#     be a deliberately PRESERVED data volume awaiting re-attachment, so it is
#     listed apart and requires a double confirmation (retype its name).
#   * Every deletion is confirmed; the default answer is "no".
#   * DRY_RUN=1 prints the report and exits (this is `make disk`).
#
# All sizing/XML comes from libvirtd (virsh), so the script needs neither sudo
# nor direct read access to /var/lib/libvirt/images — only membership in the
# libvirt group, exactly like the vol-list you already run.
#
# Environment:
#   POOL     libvirt storage pool to inspect   (default: default)
#   GOLDEN   golden image stem to protect      (default: kali-golden)
#   CONN     libvirt connection URI            (default: qemu:///system)
#   DRY_RUN  1 = report only, no prompts       (default: 0)
set -euo pipefail

# Force a stable, English locale: libvirt state strings ("running", "shut off")
# are localized otherwise (e.g. "en cours d'exécution"), which would break the
# running-vs-shutoff test and could offer a LIVE VM for teardown.
export LC_ALL=C LANG=C

POOL="${POOL:-default}"
GOLDEN="${GOLDEN:-kali-golden}"
CONN="${CONN:-qemu:///system}"
DRY_RUN="${DRY_RUN:-0}"
VIRSH=(virsh -c "$CONN")

command -v virsh >/dev/null 2>&1 || { echo "virsh not found" >&2; exit 1; }

hr()  { printf '%*s\n' 82 '' | tr ' ' '-'; }
gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }

# A pool volume that is a lab data disk (DATA= feature): "<vm>-data.raw".
is_data_disk() { [[ "$1" == *-data.* ]]; }

# --- collect the pool's volumes ------------------------------------------
mapfile -t vols < <("${VIRSH[@]}" vol-list --pool "$POOL" 2>/dev/null \
                     | awk 'NR>2 && $1!="" {print $1}')
[ "${#vols[@]}" -gt 0 ] || { echo "No volumes in pool '$POOL'." >&2; exit 0; }

declare -A VPATH VCAP VALLOC    # name -> path / capacity / allocation (bytes)
declare -A IS_BACKING           # absolute path -> 1 if it backs another volume

for v in "${vols[@]}"; do
  p="$("${VIRSH[@]}" vol-path --pool "$POOL" "$v" 2>/dev/null || true)"
  [ -n "$p" ] || continue
  VPATH["$v"]="$p"

  xml="$("${VIRSH[@]}" vol-dumpxml --pool "$POOL" "$v" 2>/dev/null || true)"
  VCAP["$v"]="$(sed -n 's/.*<capacity[^>]*>\([0-9]\+\)<.*/\1/p'   <<<"$xml" | head -n1)"
  VALLOC["$v"]="$(sed -n 's/.*<allocation[^>]*>\([0-9]\+\)<.*/\1/p' <<<"$xml" | head -n1)"

  # A qcow2 overlay records its parent inside <backingStore><path>…</path>.
  bpath="$(sed -n '/<backingStore>/,/<\/backingStore>/p' <<<"$xml" \
            | sed -n 's@.*<path>\(.*\)</path>.*@\1@p' | head -n1)"
  [ -n "$bpath" ] && IS_BACKING["$bpath"]=1
done

# --- map every disk (by VOLUME NAME) to the domain that uses it ----------
# A domain disk's Source may be a full path (file-backed) OR a bare volume
# name (type='volume', as dmacvicar attaches the root disk). Reduce both to
# the pool volume name (basename) so the match is immune to that difference.
declare -A NAME_DOM NAME_STATE
mapfile -t doms < <("${VIRSH[@]}" list --all --name 2>/dev/null | awk 'NF')
for d in "${doms[@]}"; do
  st="$("${VIRSH[@]}" domstate "$d" 2>/dev/null || echo unknown)"
  while read -r src; do
    [ -n "$src" ] && [ "$src" != "-" ] || continue
    nm="${src##*/}"            # basename, or the volume name as-is
    NAME_DOM["$nm"]="$d"
    NAME_STATE["$nm"]="$st"
  done < <("${VIRSH[@]}" domblklist "$d" 2>/dev/null | awk 'NR>2 {print $NF}')
done

# --- report + classification ---------------------------------------------
echo "Libvirt pool: $POOL   (connection: $CONN,  protected golden stem: $GOLDEN)"
hr
printf "%-26s %12s %12s  %s\n" "VOLUME" "VIRTUAL" "ALLOCATED" "STATUS"
hr

total=0; reclaimable=0
# Initialise as empty arrays (NOT `declare -a` without assignment): under
# `set -u`, an array that never received an element is treated as unset by
# some bash versions, so `${#ORPHANS[@]}` would raise "unbound variable".
ORPHANS=(); DATA_ORPHANS=()
declare -A DOM_FOOTPRINT        # shut-off domain -> reclaimable bytes

for v in "${vols[@]}"; do
  p="${VPATH[$v]:-}"; [ -n "$p" ] || continue
  alloc="${VALLOC[$v]:-0}"; cap="${VCAP[$v]:-0}"
  total=$(( total + alloc ))
  status=""

  if [ -n "${IS_BACKING[$p]:-}" ] || [[ "$v" == "$GOLDEN" || "$v" == "$GOLDEN".* ]]; then
    status="BASE / golden (protected)"
  elif [ -n "${NAME_DOM[$v]:-}" ]; then
    dom="${NAME_DOM[$v]}"; dst="${NAME_STATE[$v]}"
    status="in use — $dom ($dst)"
    if [ "$dst" != "running" ]; then
      DOM_FOOTPRINT["$dom"]=$(( ${DOM_FOOTPRINT["$dom"]:-0} + alloc ))
      reclaimable=$(( reclaimable + alloc ))
    fi
  elif is_data_disk "$v"; then
    status="DETACHED data disk (preserved?)"
    DATA_ORPHANS+=("$v")
    reclaimable=$(( reclaimable + alloc ))
  else
    status="ORPHAN (no domain)"
    ORPHANS+=("$v")
    reclaimable=$(( reclaimable + alloc ))
  fi

  printf "%-26s %12s %12s  %s\n" "$v" "$(gib "$cap")" "$(gib "$alloc")" "$status"
done

hr
printf "%-26s %12s %12s\n" "TOTAL allocated" "" "$(gib "$total")"
printf "%-26s %12s %12s\n" "Reclaimable (est.)" "" "$(gib "$reclaimable")"
hr

[ "$DRY_RUN" = "1" ] && exit 0

# --- interactive reclamation ---------------------------------------------
confirm() {
  local ans
  # Write the prompt straight to the terminal: `read -p` sends its prompt to
  # stderr, so suppressing stderr would hide the question entirely.
  printf '%s [y/N] ' "$1" >/dev/tty 2>/dev/null || true
  read -r ans </dev/tty 2>/dev/null || return 1
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# Second gate for data disks: the user must retype the exact volume name.
confirm_name() {
  local name="$1" ans
  printf "  To DELETE '%s', retype its exact name (anything else skips): " "$name" \
         >/dev/tty 2>/dev/null || true
  read -r ans </dev/tty 2>/dev/null || return 1
  [ "$ans" = "$name" ]
}

# Delete a pool volume by name, unless it is a protected base image.
del_vol() {
  local nm="$1" p="${VPATH[$1]:-}"
  if { [ -n "$p" ] && [ -n "${IS_BACKING[$p]:-}" ]; } \
     || [[ "$nm" == "$GOLDEN" || "$nm" == "$GOLDEN".* ]]; then
    echo "  kept (base image): $nm"; return 0
  fi
  if "${VIRSH[@]}" vol-delete --pool "$POOL" "$nm" >/dev/null 2>&1; then
    echo "  deleted $nm"
  else
    echo "  could NOT delete $nm"
  fi
}

echo
echo "== Old VMs (defined but shut off) =="
found=0
for d in "${doms[@]}"; do
  st="$("${VIRSH[@]}" domstate "$d" 2>/dev/null || true)"
  [ "$st" = "running" ] && continue          # never touch a live VM
  found=1
  if confirm "Tear down VM '$d' and delete its disks ($(gib "${DOM_FOOTPRINT[$d]:-0}"))?"; then
    # Collect its disk volume names BEFORE undefining.
    mapfile -t dps < <("${VIRSH[@]}" domblklist "$d" 2>/dev/null \
                        | awk 'NR>2 && $NF!="-" {print $NF}')
    "${VIRSH[@]}" undefine "$d" --nvram >/dev/null 2>&1 \
      || "${VIRSH[@]}" undefine "$d" >/dev/null 2>&1 || true
    for dp in "${dps[@]}"; do
      [ -n "$dp" ] || continue
      del_vol "${dp##*/}"
    done
  fi
done
[ "$found" = 0 ] && echo "(none)"

echo
echo "== Orphaned volumes (no domain) =="
if [ "${#ORPHANS[@]}" -eq 0 ]; then
  echo "(none)"
else
  for v in "${ORPHANS[@]}"; do
    [ -n "${NAME_DOM[$v]:-}" ] && continue    # defensive: still attached
    if confirm "Delete orphaned volume '$v' ($(gib "${VALLOC[$v]:-0}"))?"; then
      del_vol "$v"
    fi
  done
fi

echo
echo "== Detached data disks — may be PRESERVED DATA (delete with care) =="
if [ "${#DATA_ORPHANS[@]}" -eq 0 ]; then
  echo "(none)"
else
  echo "  These *-data.raw volumes are attached to no domain, but the DATA="
  echo "  design keeps them so a later 'make deploy DATA=true' can re-attach"
  echo "  their contents. Deleting one destroys that data permanently."
  for v in "${DATA_ORPHANS[@]}"; do
    [ -n "${NAME_DOM[$v]:-}" ] && continue    # defensive: still attached
    if confirm "Consider deleting data disk '$v' ($(gib "${VALLOC[$v]:-0}"))?"; then
      if confirm_name "$v"; then
        del_vol "$v"
      else
        echo "  skipped $v"
      fi
    fi
  done
fi

echo
echo "Done. Re-run 'make disk' to see the new footprint."
