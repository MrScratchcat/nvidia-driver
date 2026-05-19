#!/usr/bin/env bash
# Rebuild + republish the APT repo from pool-source/.
#
# Workflow for adding a new driver:
#   1. Drop new upstream .deb files into pool-source/
#   2. Run ./update-repo.sh
# The script:
#   - repacks each .deb to substitute the upstream version tag with our brand,
#   - sanitizes filenames (~ -> ., 1pop1 -> 1lwl1),
#   - regenerates Packages with fresh hashes/sizes from the repacked .debs,
#   - signs Release with our GPG key,
#   - uploads everything to the GitHub Release (delete stale assets, clobber the rest).

set -euo pipefail
cd "$(dirname "$0")"

REPO=MrScratchcat/nvidia-driver
TAG=apt-resolute-v1
SUITE=resolute
KEY_ID=FE87C31F7473ACB0
REBRAND_FROM=1pop1
REBRAND_TO=1lwl1
ORIGIN="${REPO}"
LABEL="nvidia-driver"
DESCRIPTION="LWL NVIDIA driver rehost (flat repo, ${SUITE})"
POP_PACKAGES_URL="http://apt.pop-os.org/release/dists/${SUITE}/main/binary-amd64/Packages.gz"

[[ -d pool-source ]] || { echo "pool-source/ missing" >&2; exit 1; }
shopt -s nullglob
poolfiles=(pool-source/*.deb)
[[ ${#poolfiles[@]} -gt 0 ]] || { echo "no .deb files in pool-source/" >&2; exit 1; }

rm -rf staged release work
mkdir -p staged release work

# Repack one .deb: rewrite control to substitute REBRAND_FROM -> REBRAND_TO,
# sanitize the output filename (~ -> ., REBRAND_FROM -> REBRAND_TO).
repack_deb() {
  local src; src=$(realpath "$1")
  local out_dir; out_dir=$(realpath "$2")
  local bn newname dst tmp ctl comp
  bn=$(basename "$src")
  newname=${bn//\~/.}
  newname=${newname//${REBRAND_FROM}/${REBRAND_TO}}
  dst="$out_dir/$newname"
  tmp=$(mktemp -d)
  (
    cd "$tmp"
    ar x "$src"
    if   [ -f control.tar.zst ]; then comp=zst;  ctl=control.tar.zst
    elif [ -f control.tar.xz  ]; then comp=xz;   ctl=control.tar.xz
    elif [ -f control.tar.gz  ]; then comp=gz;   ctl=control.tar.gz
    elif [ -f control.tar     ]; then comp=none; ctl=control.tar
    else echo "no control.tar in $bn" >&2; exit 1; fi
    mkdir ctl-x
    case $comp in
      zst)  zstd -d -q -c "$ctl" | tar -xC ctl-x ;;
      xz)   xz -d -c "$ctl" | tar -xC ctl-x ;;
      gz)   gunzip -c "$ctl" | tar -xC ctl-x ;;
      none) tar -xf "$ctl" -C ctl-x ;;
    esac
    if grep -rl -F "$REBRAND_FROM" ctl-x >/dev/null 2>&1; then
      grep -rl -F "$REBRAND_FROM" ctl-x | xargs sed -i "s/${REBRAND_FROM}/${REBRAND_TO}/g"
    fi
    (cd ctl-x && tar --owner=0 --group=0 --numeric-owner --format=gnu -cf ../control.tar.new .)
    case $comp in
      zst)  zstd -q -f -o "${ctl}.new" control.tar.new && mv "${ctl}.new" "$ctl" ;;
      xz)   xz -c < control.tar.new > "$ctl" ;;
      gz)   gzip -c < control.tar.new > "$ctl" ;;
      none) mv control.tar.new "$ctl" ;;
    esac
    rm -f control.tar.new
    rm -f "$dst"
    ar -rD "$dst" debian-binary "$ctl" data.tar*
  )
  rm -rf "$tmp"
}

# Pass 1: repack each .deb into staged/
echo "Repacking ${#poolfiles[@]} .deb files..."
for src in "${poolfiles[@]}"; do
  repack_deb "$src" staged
done
echo "  -> $(ls staged/*.deb | wc -l) files in staged/"

# Pass 2: pull upstream Packages.gz and emit our rewritten Packages.
ls staged/*.deb | xargs -n1 basename | sort > work/have-list.txt
curl -sLf "$POP_PACKAGES_URL" | gunzip -c > work/pop-Packages.txt

awk -v rebrand_from="$REBRAND_FROM" -v rebrand_to="$REBRAND_TO" -v staged_dir="$(pwd)/staged" '
function sanitize(s,   x) { x=s; gsub(/~/, ".", x); return x }
function rebrand(s,   x) { x=s; gsub(rebrand_from, rebrand_to, x); return x }
function hash_of(file, algo,   cmd, line, a) {
  cmd = algo "sum \"" file "\""
  cmd | getline line; close(cmd)
  split(line, a, " "); return a[1]
}
function size_of(file,   cmd, n) {
  cmd = "wc -c < \"" file "\""
  cmd | getline n; close(cmd); return n+0
}
BEGIN {
  while ((getline line < "work/have-list.txt") > 0) have[line] = 1
  close("work/have-list.txt")
  RS=""; FS="\n"
}
{
  fn=""
  for (i=1; i<=NF; i++) if ($i ~ /^Filename: /) fn = substr($i, 11)
  if (fn == "") next
  n = split(fn, parts, "/")
  new_bn = rebrand(sanitize(parts[n]))
  if (!(new_bn in have)) next

  path = staged_dir "/" new_bn
  new_size = size_of(path)
  new_md5  = hash_of(path, "md5")
  new_sha1 = hash_of(path, "sha1")
  new_sha256 = hash_of(path, "sha256")
  new_sha512 = hash_of(path, "sha512")

  for (i=1; i<=NF; i++) {
    line = $i
    if      (line ~ /^Filename: /) print "Filename: " new_bn
    else if (line ~ /^Size: /)     print "Size: " new_size
    else if (line ~ /^MD5sum: /)   print "MD5sum: " new_md5
    else if (line ~ /^SHA1: /)     print "SHA1: " new_sha1
    else if (line ~ /^SHA256: /)   print "SHA256: " new_sha256
    else if (line ~ /^SHA512: /)   print "SHA512: " new_sha512
    else { gsub(rebrand_from, rebrand_to, line); print line }
  }
  print ""
  matched[new_bn] = 1
}
END {
  for (k in have) if (!(k in matched)) print "WARNING: no upstream stanza for " k > "/dev/stderr"
}
' work/pop-Packages.txt > release/Packages

stanzas=$(grep -c '^Package:' release/Packages)
expected=$(wc -l < work/have-list.txt)
echo "Packages: $stanzas stanzas for $expected staged files"
[[ "$stanzas" -eq "$expected" ]] || { echo "stanza count mismatch; aborting" >&2; exit 1; }
gzip -kf release/Packages

# Pass 3: Release + signatures
cd release
{
  echo "Origin: $ORIGIN"
  echo "Label: $LABEL"
  echo "Suite: $SUITE"
  echo "Codename: $SUITE"
  echo "Date: $(date -Ru | sed 's/+0000/UTC/')"
  echo "Architectures: amd64"
  echo "Description: $DESCRIPTION"
  for spec in MD5Sum:md5 SHA1:sha1 SHA256:sha256; do
    field=${spec%:*}; algo=${spec#*:}
    echo "$field:"
    for f in Packages Packages.gz; do
      size=$(wc -c < "$f")
      h=$("${algo}sum" "$f" | awk '{print $1}')
      printf " %s %16d %s\n" "$h" "$size" "$f"
    done
  done
} > Release
rm -f Release.gpg InRelease
gpg --batch --yes --local-user "$KEY_ID" --armor --detach-sign --output Release.gpg Release
gpg --batch --yes --local-user "$KEY_ID" --clearsign --output InRelease Release
cd ..

# Pass 4: stage metadata alongside .debs for upload, then sync the Release.
cp release/Release release/Release.gpg release/InRelease release/Packages release/Packages.gz staged/
rm -rf work

echo "Syncing Release assets..."
new_assets=$(ls staged/ | sort -u)
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  existing_assets=$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name' | sort -u)
  comm -23 <(echo "$existing_assets") <(echo "$new_assets") | while read -r name; do
    [ -z "$name" ] && continue
    echo "  delete stale: $name"
    gh release delete-asset "$TAG" "$name" --repo "$REPO" --yes >/dev/null
  done
  gh release upload "$TAG" staged/* --repo "$REPO" --clobber
else
  gh release create "$TAG" staged/* \
    --repo "$REPO" \
    --target main \
    --title "APT repo for ${LABEL} (${SUITE})" \
    --notes "Flat APT repo. Use: \`deb [signed-by=/etc/apt/keyrings/nvidia-driver.gpg] https://github.com/${REPO}/releases/download/${TAG} ./\`"
fi

echo "Done. Verify:"
echo "  curl -fL https://github.com/${REPO}/releases/download/${TAG}/InRelease | gpg --verify"
