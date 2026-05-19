#!/usr/bin/env bash
# Rebuild + republish the APT repo from pool-source/.
#
# Workflow for adding a new driver:
#   1. Drop new Pop OS .deb files into pool-source/
#   2. Run ./update-repo.sh
# The script sanitizes filenames, regenerates Packages/Release, signs them,
# and uploads everything to the GitHub Release (clobbering existing assets).

set -euo pipefail
cd "$(dirname "$0")"

REPO=MrScratchcat/nvidia-driver
TAG=apt-resolute-v1
SUITE=resolute
KEY_ID=769C4EAEED34AE44
POP_PACKAGES_URL="http://apt.pop-os.org/release/dists/${SUITE}/main/binary-amd64/Packages.gz"

[[ -d pool-source ]] || { echo "pool-source/ is missing" >&2; exit 1; }
[[ -n "$(ls pool-source/*.deb 2>/dev/null)" ]] || { echo "no .deb files in pool-source/" >&2; exit 1; }

rm -rf staged release
mkdir -p staged release

# 1. Hardlink sanitized copies into staged/.
for src in pool-source/*.deb; do
  bn=$(basename "$src")
  san=${bn//\~/.}
  ln -f "$src" "staged/$san"
done
ls staged/ | sort > staged/.have-list.txt

# 2. Pull Pop OS Packages.gz and select matching stanzas, rewriting Filename.
curl -sLf "$POP_PACKAGES_URL" | gunzip -c > staged/.pop-Packages.txt

awk '
BEGIN {
  while ((getline line < "staged/.have-list.txt") > 0) have[line] = 1
  close("staged/.have-list.txt")
  RS=""; FS="\n"
}
{
  fn=""
  for (i=1; i<=NF; i++) if ($i ~ /^Filename: /) fn = substr($i, 11)
  if (fn == "") next
  n = split(fn, parts, "/")
  bn = parts[n]; san = bn; gsub(/~/, ".", san)
  if (!(san in have)) next
  for (i=1; i<=NF; i++) {
    if ($i ~ /^Filename: /) print "Filename: " san
    else print $i
  }
  print ""
  matched[san] = 1
}
END {
  for (k in have) if (!(k in matched)) print "WARNING: no Pop OS stanza for " k > "/dev/stderr"
}
' staged/.pop-Packages.txt > release/Packages

stanzas=$(grep -c '^Package:' release/Packages)
have_count=$(wc -l < staged/.have-list.txt)
echo "Generated $stanzas stanzas for $have_count staged .debs"
[[ "$stanzas" -eq "$have_count" ]] || { echo "stanza count != staged file count; aborting" >&2; exit 1; }

# 3. Compress Packages.
gzip -kf release/Packages

# 4. Generate Release file with hashes.
cd release
{
  echo "Origin: $REPO"
  echo "Label: nvidia-driver"
  echo "Suite: $SUITE"
  echo "Codename: $SUITE"
  echo "Date: $(date -Ru | sed 's/+0000/UTC/')"
  echo "Architectures: amd64"
  echo "Description: Pop OS NVIDIA driver rehost (flat repo, ${SUITE})"
  for label in MD5Sum:md5 SHA1:sha1 SHA256:sha256; do
    field=${label%:*}; algo=${label#*:}
    echo "$field:"
    for f in Packages Packages.gz; do
      size=$(wc -c < "$f")
      h=$("${algo}sum" "$f" | awk '{print $1}')
      printf " %s %16d %s\n" "$h" "$size" "$f"
    done
  done
} > Release

# 5. Sign.
rm -f Release.gpg InRelease
gpg --batch --yes --local-user "$KEY_ID" --armor --detach-sign --output Release.gpg Release
gpg --batch --yes --local-user "$KEY_ID" --clearsign --output InRelease Release
cd ..

# 6. Collect everything to upload.
cp release/Release release/Release.gpg release/InRelease release/Packages release/Packages.gz staged/
rm -f staged/.have-list.txt staged/.pop-Packages.txt

# 7. Upload to Release (clobber).
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists; uploading with --clobber"
  gh release upload "$TAG" staged/* --repo "$REPO" --clobber
else
  echo "Creating Release $TAG"
  gh release create "$TAG" staged/* \
    --repo "$REPO" \
    --title "APT repo for Pop OS NVIDIA driver (${SUITE})" \
    --notes "Flat APT repo. \`deb [signed-by=...] https://github.com/${REPO}/releases/download/${TAG} ./\`"
fi

echo "Done. Verify with:"
echo "  curl -fI https://github.com/${REPO}/releases/download/${TAG}/InRelease"
