#!/usr/bin/env bash
# Summarize "path count" lines and emit scoped fapolicyd dir rules.
# Works on files where each line is:  /absolute/path  <count>
#
# Env:
#   LOG=/var/log/fapolicyd/fapolicyd-access.log   # input file
#   LEVELS=3                                      # components to keep in common-denominator dir
#   TAIL_LINES=0                                  # 0 = whole file, else last N lines only

set -eo pipefail

LOG="${LOG:-/var/log/fapolicyd/fapolicyd-access.log}"
LEVELS="${LEVELS:-3}"
TAIL_LINES="${TAIL_LINES:-0}"

[[ -r "$LOG" ]] || { echo "Cannot read $LOG"; exit 1; }

# If you only want the tail, make a temp view
if [[ "$TAIL_LINES" -gt 0 ]]; then
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  tail -n "$TAIL_LINES" "$LOG" > "$TMP"
  IN="$TMP"
else
  IN="$LOG"
fi

# Detect format: lines like "/path  N"
if ! awk 'BEGIN{ok=0}
  /^[[:space:]]*\/[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]*$/ {ok=1; exit}
  END{exit ok?0:1}' "$IN"
then
  echo "Input does not look like \"path count\" lines. Expected lines like: /some/path<space>42"
  exit 1
fi

# AWK does all the grouping and aggregation
# topdir() keeps only LEVELS components from the start, eg:
#  LEVELS=2 => /opt/jfrog
#  LEVELS=3 => /usr/lib/jvm
awk -v LEVELS="$LEVELS" '
function dirname(p,    i,n,seg,out){
  gsub(/\/+/, "/", p)
  n=split(p,seg,"/")
  if (n<=2) return "/"
  out=""
  for (i=1;i<n;i++) if (seg[i]!="") out=out "/" seg[i]
  return out
}
function topdir(d,    i,n,seg,out,cnt){
  gsub(/\/+/, "/", d)
  n=split(d,seg,"/")
  out=""; cnt=0
  for (i=2; i<=n && cnt<LEVELS; i++) { out=out "/" seg[i]; cnt++ }
  if (out=="") out="/"
  return out
}
# Accept: /abs/path  <count>
/^[[:space:]]*\/[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]*$/ {
  path=$1; cnt=$NF+0
  d = dirname(path)
  key = topdir(d)
  sum[key] += cnt
  next
}
END{
  for (k in sum) printf "%d\t%s\n", sum[k], k
}
' "$IN" \
| sort -k1,1nr -k2,2 \
| awk -F'\t' -v LOG="$LOG" -v LEVELS="$LEVELS" -v TAIL="$TAIL_LINES" '
BEGIN{
  print "fapolicyd directory frequency summary"
  print "Log: " LOG
  if (TAIL>0) print "Scope: last " TAIL " lines"
  print "Grouping depth (LEVELS): " LEVELS
  print ""
  printf "%-8s %s\n","Count","Directory"
}
{
  printf "%-8s %s\n",$1,$2
  lines[NR]=$0
}
END{
  print ""
  print "Suggested allow rules (common-denominator directories):"
  print ""
  for (i=1;i<=NR;i++){
    split(lines[i],a,"\t")
    dir=a[2]
    print "allow perm=any all : dir=" dir
  }
}
'
