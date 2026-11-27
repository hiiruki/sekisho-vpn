#!/bin/sh
# Release notes for the latest vX.Y.Z tag from the Conventional Commits since the tag before it:
# feat → New, fix → Fixed, "type!:" or BREAKING CHANGE → Breaking changes; docs, ci, build, test, refactor are left out.
# Usage: release-notes.sh md|html   (md for the GitHub release, html for the Sparkle update dialog)
set -e
FORMAT=${1:-md}
TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*')
PREV=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$TAG^" 2>/dev/null || true)
git log --no-merges --format='%s%x1f%b%x1e' "${PREV:+$PREV..}$TAG" | awk -v fmt="$FORMAT" '
function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
function section(title, items, n,   i) {
  if (n == 0) return
  if (fmt == "html") {
    printf "<h3>%s</h3>\n<ul>\n", title
    for (i = n; i >= 1; i--) printf "<li>%s</li>\n", esc(items[i]) # git log is newest first; list oldest first
    print "</ul>"
  } else {
    printf "### %s\n\n", title
    for (i = n; i >= 1; i--) printf "- %s\n", items[i]
    print ""
  }
}
BEGIN { RS = "\036"; FS = "\037" }
{
  subject = $1; sub(/^\n+/, "", subject)
  if (subject !~ /^[a-z]+(\([^)]*\))?!?: /) next
  type = subject; sub(/[(!:].*/, "", type)
  text = subject; sub(/^[^:]*: /, "", text); text = toupper(substr(text, 1, 1)) substr(text, 2)
  if (subject ~ /^[a-z]+(\([^)]*\))?!: / || $2 ~ /BREAKING CHANGE/) breaking[++nb] = text
  else if (type == "feat") added[++na] = text
  else if (type == "fix") fixed[++nf] = text
}
END { section("Breaking changes", breaking, nb); section("New", added, na); section("Fixed", fixed, nf) }'
