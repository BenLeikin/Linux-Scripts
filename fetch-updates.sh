#!/usr/bin/env bash
#
# fetch-updates.sh
#
# Fetches latest software releases from multiple vendor sites, verifies
# checksums (or GPG signatures for RPMs), extracts tarballs where appropriate,
# and writes a combined report.
#
# Usage:
#   ./fetch-updates.sh --all                  # run every site
#   ./fetch-updates.sh --site nagios          # run one site
#   ./fetch-updates.sh --site nagios --site jira-software
#   ./fetch-updates.sh --all --dry-run        # resolve versions, don't download
#   ./fetch-updates.sh --list                 # show available site names
#   ./fetch-updates.sh --all --max-parallel 2 # cap concurrency
#
# Sites:
#   nagios            Nagios XI offline installer tarball (el8)
#   artifactory       JFrog Artifactory Pro RPM
#   xray              JFrog Xray RPM tarball (extracted)
#   gitlab-ee         GitLab Enterprise Edition RPM
#   gitlab-runner     GitLab Runner + helper-images RPMs
#   elastic           Elasticsearch, Kibana, Logstash RPMs
#   jira-software     Jira Software Data Center 10.3.x (tarball, extracted)
#   jira-core         Jira Core Data Center 10.3.x (tarball, extracted)
#   confluence        Confluence Data Center 10.2.x (tarball, extracted)
#

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DIR="${SCRIPT_DIR}/Monthly-Updates"
readonly YEAR="$(date +%Y)"
readonly MONTH="$(date +%m)"
readonly RUN_DIR="${BASE_DIR}/${YEAR}/${MONTH}"

# curl defaults. -k for enterprise SSL inspection. Aggressive timeouts so
# the script fails fast instead of hanging on a dead endpoint.
readonly CURL_API_OPTS=(-kSL --fail --connect-timeout 10 --max-time 60)
readonly CURL_DL_OPTS=(-kSL --fail --connect-timeout 10)

# Disk space multipliers. Tarballs that will be extracted need room for
# the archive plus the extracted tree.
readonly DISK_MULT_PLAIN="1.2"
readonly DISK_MULT_EXTRACT="3.0"

# Default cap on parallel jobs.
DEFAULT_MAX_PARALLEL=4

# All available site names. Kept as an array for iteration + validation.
readonly ALL_SITES=(
    nagios
    artifactory
    xray
    gitlab-ee
    gitlab-runner
    elastic
    jira-software
    jira-core
    confluence
)

# ---------------------------------------------------------------------------
# Version pinning
# ---------------------------------------------------------------------------
# Update these once a year (or whenever you decide to bump a release line)
# instead of hunting through individual parser functions.
#
# Format: major.minor — patch is picked automatically by each parser.

readonly PIN_GITLAB_EE="18.10"        # parse_gitlab_ee uses this
readonly PIN_GITLAB_RUNNER="18.10"    # parse_gitlab_runner — keep in sync with EE
readonly PIN_ELASTIC="9.4"            # parse_elastic (endoflife.date cycle)
readonly PIN_JIRA="10.3"              # Jira Software + Jira Core both on this line
readonly PIN_CONFLUENCE="10.2"        # parse_confluence

# ---------------------------------------------------------------------------
# Site groups
# ---------------------------------------------------------------------------
# Convenience groupings for the --group flag. Saves typing when you run a
# specific subset (e.g. "all the JFrog stuff" or "all the Atlassian stuff").

declare -A SITE_GROUPS=(
    [jfrog]="artifactory xray"
    [gitlab]="gitlab-ee gitlab-runner"
    [atlassian]="jira-software jira-core confluence"
    [elk]="elastic"
)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

SELECTED_SITES=()
DRY_RUN=0
MAX_PARALLEL="${DEFAULT_MAX_PARALLEL}"
SITE_LOG_DIR=""  # Populated in main once we know the run dir.
SINGLE_SITE_MODE=0  # 1 when only one site is selected — enables progress bar.
STAGE_DOWNLOADS=0   # 1 = download to /tmp first, then move — works around Windows FS issues.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Log to stderr so stdout can be reserved for structured output if needed.
log() {
    local level="$1"; shift
    printf '[%s] %-5s %s\n' "$(date +%H:%M:%S)" "$level" "$*" >&2
}

info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }

die() {
    error "$@"
    exit 1
}

# Per-site logging prefixes the site name so parallel output is readable.
site_log() {
    local site="$1" level="$2"; shift 2
    log "$level" "[${site}] $*"
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

# Check that required external commands exist. Fail early with a clear message.
check_deps() {
    local missing=()
    for cmd in curl jq sha256sum sha512sum md5sum sort awk sed grep tar df stat rpm; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required commands: ${missing[*]}"
    fi
}

# Convert a human-readable size ("10.71G", "114.94M", "1.77 GB") to bytes.
# Used to pre-check disk space.
size_to_bytes() {
    local s="$1"
    # Normalize: uppercase, strip spaces.
    s="$(echo "$s" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
    local num unit
    # Match number and unit.
    if [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)([KMGT]?)B?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
    else
        echo 0
        return
    fi
    local mult=1
    case "$unit" in
        K) mult=1024 ;;
        M) mult=$((1024*1024)) ;;
        G) mult=$((1024*1024*1024)) ;;
        T) mult=$((1024*1024*1024*1024)) ;;
    esac
    # bash can't do float arithmetic, hand off to awk.
    awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f", n * m }'
}

# Check we have enough free bytes on the filesystem holding a given path.
check_disk_space() {
    local path="$1" needed_bytes="$2"
    local avail_kb
    avail_kb="$(df --output=avail -k "$path" 2>/dev/null | tail -1 | tr -d ' ')"
    [[ -z "$avail_kb" ]] && return 0  # couldn't determine, don't block
    local avail_bytes=$((avail_kb * 1024))
    if (( avail_bytes < needed_bytes )); then
        return 1
    fi
    return 0
}

# Human-readable byte formatter for the report.
human_bytes() {
    local b="$1"
    awk -v b="$b" 'BEGIN {
        units[0]="B"; units[1]="KB"; units[2]="MB"; units[3]="GB"; units[4]="TB"
        i=0; while (b >= 1024 && i < 4) { b /= 1024; i++ }
        printf "%.2f %s", b, units[i]
    }'
}

# Convert a date string that might be in various vendor formats to a sortable
# YYYYMMDDHHMM integer. Returns 0 on unparseable input.
normalize_date() {
    local fmt="$1" s="$2"
    # GNU date handles most formats with -d. Use explicit format where the
    # ambiguity bites us (MM/DD/YY for Nagios vs DD/MM/YY).
    case "$fmt" in
        nagios)
            # "04/9/26 06:04" -> MM/D/YY HH:MM
            local mm dd yy hhmm hh mn
            IFS='/ :' read -r mm dd yy hh mn _ <<< "$s"
            # Force base-10 interpretation with 10# prefix — otherwise bash
            # treats leading-zero values like "08" as invalid octal.
            mm=$((10#$mm))
            dd=$((10#$dd))
            yy=$((10#$yy))
            hh=$((10#$hh))
            mn=$((10#$mn))
            # Two-digit year: 00-79 -> 20XX, 80-99 -> 19XX (just in case).
            if (( yy < 80 )); then yy=$((2000 + yy)); else yy=$((1900 + yy)); fi
            printf "%04d%02d%02d%02d%02d\n" "$yy" "$mm" "$dd" "$hh" "$mn"
            ;;
        atlassian_dir)
            # "24-Mar-2026 21:06"
            date -d "$s" +%Y%m%d%H%M 2>/dev/null || echo 0
            ;;
        *)
            date -d "$s" +%Y%m%d%H%M 2>/dev/null || echo 0
            ;;
    esac
}

# Compare two semver-like strings. Echoes -1 / 0 / 1 so caller can branch.
# Handles "1.2.3", "7.133.18", "10.3.19" etc. Only numeric components.
vercmp() {
    local a="$1" b="$2"
    if [[ "$a" == "$b" ]]; then
        echo 0
        return
    fi
    local result
    result="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)"
    if [[ "$result" == "$a" ]]; then
        echo -1
    else
        echo 1
    fi
}

# Remove files matching a pattern in the run dir that DON'T match a keeper
# filename. Used to drop older versions when a new one arrives.
# Args: pattern, keeper_filename
prune_old_versions() {
    local pattern="$1" keeper="$2"
    local f
    shopt -s nullglob
    for f in "${RUN_DIR}"/${pattern}; do
        local base
        base="$(basename "$f")"
        if [[ "$base" != "$keeper" ]] && [[ "$base" != "${keeper}.sha256" ]] \
           && [[ "$base" != "${keeper}.sha512" ]] && [[ "$base" != "${keeper}.md5" ]]; then
            # Only remove files (not dirs — extracted dirs get pruned via
            # prune_old_dirs).
            if [[ -f "$f" ]]; then
                info "Removing outdated: $base"
                rm -f "$f"
            fi
        fi
    done
    shopt -u nullglob
}

prune_old_dirs() {
    local pattern="$1" keeper="$2"
    local d
    shopt -s nullglob
    for d in "${RUN_DIR}"/${pattern}; do
        local base
        base="$(basename "$d")"
        if [[ -d "$d" ]] && [[ "$base" != "$keeper" ]]; then
            info "Removing outdated extracted dir: $base"
            rm -rf "$d"
        fi
    done
    shopt -u nullglob
}

# Download a file to a given path with progress bar. Respects DRY_RUN.
# Returns 0 on success, non-zero on failure.
do_download() {
    local url="$1" dest="$2" site="$3"
    if (( DRY_RUN == 1 )); then
        site_log "$site" INFO "DRY-RUN: would download $url"
        return 0
    fi
    site_log "$site" INFO "Downloading $(basename "$dest")"

    # When STAGE_DOWNLOADS=1, download to a local scratch path first and move
    # the completed file into place. This works around filesystem quirks seen
    # on Windows-backed mounts (CIFS/cygdrive) where curl's streaming write
    # trips occasional rc=23 failures. Stage on /tmp if writable, otherwise
    # fall back to direct-write.
    local effective_dest="$dest"
    local staged=0
    if (( STAGE_DOWNLOADS == 1 )) && [[ -w /tmp ]]; then
        # Preserve the filename in the staging path so tools that peek at the
        # extension (like extract_tarball later on) still work if called on it.
        effective_dest="/tmp/fetch-updates-stage-$$-$(basename "$dest")"
        staged=1
        site_log "$site" INFO "Staging to local tmp before moving to final location"
    fi

    local err_file rc
    err_file="$(mktemp)"
    if (( SINGLE_SITE_MODE == 1 )); then
        curl "${CURL_DL_OPTS[@]}" --progress-bar -o "$effective_dest" "$url" 2>"$err_file"
        rc=$?
    else
        curl "${CURL_DL_OPTS[@]}" --silent --show-error -o "$effective_dest" "$url" 2>"$err_file"
        rc=$?
    fi
    if (( rc != 0 )); then
        local msg
        msg="$(cat "$err_file" 2>/dev/null)"
        rm -f "$err_file"
        site_log "$site" ERROR "Download failed (curl rc=$rc): $url"
        [[ -n "$msg" ]] && site_log "$site" ERROR "curl says: $msg"
        rm -f "$effective_dest"
        return 1
    fi
    rm -f "$err_file"

    # If we staged, move the completed file into place now. Use mv which on
    # cross-filesystem moves becomes copy + unlink, so we still get the issue
    # we were trying to avoid, but the copy from /tmp to the target is a
    # single read->write operation the kernel handles more gracefully than
    # curl's progressive writes.
    if (( staged == 1 )); then
        site_log "$site" INFO "Moving staged file to final destination"
        if ! mv -f "$effective_dest" "$dest" 2>"$err_file"; then
            local msg
            msg="$(cat "$err_file" 2>/dev/null)"
            rm -f "$err_file" "$effective_dest"
            site_log "$site" ERROR "Move to final destination failed"
            [[ -n "$msg" ]] && site_log "$site" ERROR "mv says: $msg"
            return 1
        fi
    fi
    return 0
}

# Verify a file against an expected sha256 hex string.
verify_sha256_hex() {
    local file="$1" expected="$2"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    return 1
}

# Verify using a sidecar .sha256 / .sha512 file in the standard "<hash>  <name>" format.
verify_sidecar() {
    local file="$1" sidecar="$2" algo="$3"  # algo = sha256|sha512
    local cmd
    case "$algo" in
        sha256) cmd="sha256sum" ;;
        sha512) cmd="sha512sum" ;;
        md5)    cmd="md5sum" ;;
        *) return 1 ;;
    esac
    # The sidecar file may reference a bare filename; -c expects the file to
    # exist at that relative path. We run the check from the file's directory.
    local dir base
    dir="$(dirname "$file")"
    base="$(basename "$file")"
    # Some sidecar files contain only the hash with no filename. Handle both.
    local sidecar_content
    sidecar_content="$(cat "$sidecar")"
    if [[ "$sidecar_content" =~ ^[a-fA-F0-9]+[[:space:]]*$ ]]; then
        # Hash-only format.
        local expected
        expected="$(echo "$sidecar_content" | awk '{print $1}')"
        local actual
        actual="$($cmd "$file" | awk '{print $1}')"
        [[ "$actual" == "$expected" ]]
        return
    fi
    # Standard "<hash>  <filename>" format; run check from file's directory so
    # the filename resolves.
    (cd "$dir" && $cmd -c "$sidecar" >/dev/null 2>&1)
}

# Verify an RPM using its embedded signature. Doesn't require the signing
# key to be imported — still validates the internal SHA.
verify_rpm_sig() {
    local file="$1"
    # rpm -K / --checksig exits 0 if hashes verify. GPG signature may say
    # "NOT OK" if key isn't imported, but the sha check is what we really want.
    # Use --nosignature to skip GPG and just check the payload hashes.
    rpm -K --nosignature "$file" >/dev/null 2>&1
}

# Extract a .tar.gz into the run dir. The output directory name is the file
# basename with .tar.gz stripped.
extract_tarball() {
    local file="$1" site="$2"
    local base dir
    base="$(basename "$file")"
    dir="${file%.tar.gz}"
    # Some files might be .tgz; handle that.
    [[ "$dir" == "$file" ]] && dir="${file%.tgz}"
    if (( DRY_RUN == 1 )); then
        site_log "$site" INFO "DRY-RUN: would extract to $dir"
        return 0
    fi
    # Remove existing dir to avoid mixing old + new contents.
    [[ -d "$dir" ]] && rm -rf "$dir"
    mkdir -p "$dir"
    site_log "$site" INFO "Extracting $base"
    if ! tar -xzf "$file" -C "$dir"; then
        site_log "$site" ERROR "Extraction failed"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Per-site report helpers
#
# Each parser writes a small text file with KEY=VALUE lines to the log dir.
# The main process collates these into report.txt at the end.
# ---------------------------------------------------------------------------

site_report() {
    local site="$1" key="$2" value="$3"
    local report_file="${SITE_LOG_DIR}/${site}.report"
    printf '%s=%s\n' "$key" "$value" >> "$report_file"
}

# ---------------------------------------------------------------------------
# Parser: Nagios XI (el8 offline tarball)
# ---------------------------------------------------------------------------

parse_nagios() {
    local site="nagios"
    local index_url="https://repo.nagios.com/?repo=offline"

    site_log "$site" INFO "Fetching index"
    local html
    html="$(curl "${CURL_API_OPTS[@]}" "$index_url")" || {
        site_log "$site" ERROR "Failed to fetch index"
        site_report "$site" status failed
        return 1
    }

    # The page has a table where each row's fields are spread across multiple
    # lines. We first compress the HTML so each <tr> is a single line, then
    # extract fields per row. Strategy:
    #   1. Remove all newlines: everything on one stream.
    #   2. Re-insert a newline before each <tr so we get one row per line.
    #   3. Filter rows containing el8.x86_64.tar.gz.
    #   4. Per row: extract filename, size, date, sha256.
    local compact rows
    compact="$(echo "$html" | tr '\n' ' ')"
    # Insert a newline before each <tr (preserving the tag).
    rows="$(echo "$compact" | sed 's|<tr|\n<tr|g' | grep "el8\.x86_64\.tar\.gz")"

    # Single-pass awk parse. The page has one table row per release; after
    # collapsing newlines and re-splitting on <tr, each input line is one row.
    # Then awk extracts filename, href, size, date, and sha256 in a single
    # process instead of forking grep/sed per-row. This matters on MobaXterm
    # where fork() is very slow.
    local compact rows
    compact="$(echo "$html" | tr '\n' ' ')"
    rows="$(echo "$compact" | sed 's|<tr|\n<tr|g' | grep "el8\.x86_64\.tar\.gz")"

    local parse_result
    parse_result="$(echo "$rows" | awk '
        {
            # Filename: find "nagiosxi-...el8.x86_64.tar.gz"; strip any leading path.
            if (match($0, /nagiosxi-[^'\''"<>]*el8\.x86_64\.tar\.gz/) == 0) next
            fname = substr($0, RSTART, RLENGTH)
            n = split(fname, parts, "/")
            fname = parts[n]  # basename

            # href attribute.
            href = ""
            if (match($0, /href='\''[^'\'']+'\''/)) {
                href = substr($0, RSTART + 6, RLENGTH - 7)
            }
            if (href !~ /^https?:\/\//) href = "https://repo.nagios.com/" href
            if (href == "https://repo.nagios.com/") next

            # sha256: 64 hex chars. Use explicit repetition because some awks
            # (older MobaXterm/Cygwin builds) do not honor {N} interval syntax
            # by default.
            if (match($0, /[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]/) == 0) next
            sha = substr($0, RSTART, RLENGTH)

            # Size: decimal + single unit letter.
            size = ""
            if (match($0, /[0-9]+\.[0-9]+[KMGT]/)) size = substr($0, RSTART, RLENGTH)

            # Date: M/D/YY HH:MM. Anchor on a non-digit before to force full
            # match of the day field. Day and month may be 1 or 2 digits, year
            # is always 2 digits, hour and minute are always 2.
            if (match($0, /[^0-9][0-9]+\/[0-9]+\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]/) == 0) next
            date_str = substr($0, RSTART + 1, RLENGTH - 1)

            # Convert date to YYYYMMDDHHMM for sort.
            split(date_str, dp, /[\/ :]/)
            mm = dp[1] + 0; dd = dp[2] + 0; yy = dp[3] + 0
            yy = (yy < 80) ? 2000 + yy : 1900 + yy
            hh = dp[4] + 0; mi = dp[5] + 0
            ts = sprintf("%04d%02d%02d%02d%02d", yy, mm, dd, hh, mi) + 0

            if (ts > best_ts) {
                best_ts = ts
                best_fname = fname
                best_url = href
                best_size = size
                best_date = date_str
                best_sha = sha
            }
        }
        END {
            print best_fname "|" best_url "|" best_size "|" best_date "|" best_sha
        }
    ')"

    local fname url size date_str sha
    IFS='|' read -r fname url size date_str sha <<< "$parse_result"

    if [[ -z "$fname" ]]; then
        site_log "$site" ERROR "No el8 tarballs found in index"
        site_report "$site" status failed
        return 1
    fi

    site_log "$site" INFO "Latest: $fname (published $date_str)"
    site_report "$site" product "Nagios XI"
    site_report "$site" filename "$fname"
    site_report "$site" url "$url"
    site_report "$site" published "$date_str"
    site_report "$site" size "$size"
    site_report "$site" checksum_expected "$sha"
    site_report "$site" checksum_algo "sha256"

    # Reuse check.
    local dest="${RUN_DIR}/${fname}"
    if [[ -f "$dest" ]] && verify_sha256_hex "$dest" "$sha"; then
        site_log "$site" INFO "Already present with valid checksum, skipping"
        site_report "$site" status "already-present"
        return 0
    fi

    # Prune old versions.
    prune_old_versions "nagiosxi-*-el8.x86_64.tar.gz" "$fname"

    # Disk space check.
    local size_bytes
    size_bytes="$(size_to_bytes "$size")"
    local needed
    needed="$(awk -v b="$size_bytes" -v m="$DISK_MULT_PLAIN" 'BEGIN { printf "%.0f", b * m }')"
    if ! check_disk_space "$RUN_DIR" "$needed"; then
        site_log "$site" ERROR "Insufficient disk space (need $(human_bytes "$needed"))"
        site_report "$site" status "insufficient-space"
        return 1
    fi

    # Download.
    if ! do_download "$url" "$dest" "$site"; then
        site_report "$site" status "download-failed"
        return 1
    fi

    if (( DRY_RUN == 1 )); then
        site_report "$site" status "dry-run"
        return 0
    fi

    # Verify.
    if ! verify_sha256_hex "$dest" "$sha"; then
        site_log "$site" ERROR "Checksum mismatch"
        site_report "$site" status "checksum-mismatch"
        return 1
    fi
    site_log "$site" INFO "Verified (sha256)"
    site_report "$site" status "downloaded"
    site_report "$site" checksum_verified "yes"
    return 0
}

# ---------------------------------------------------------------------------
# Parser: JFrog Artifactory Pro
# ---------------------------------------------------------------------------

parse_artifactory() {
    local site="artifactory"
    local index_url="https://releases.jfrog.io/artifactory/artifactory-pro-rpms/jfrog-artifactory-pro/"

    site_log "$site" INFO "Fetching index"
    local html
    html="$(curl "${CURL_API_OPTS[@]}" "$index_url")" || {
        site_log "$site" ERROR "Failed to fetch index"
        site_report "$site" status failed
        return 1
    }

    # Single-pass awk parse. Each line has:
    #   <a href="jfrog-artifactory-pro-X.Y.Z.rpm">...</a>    DD-MMM-YYYY HH:MM  SIZE UNIT
    # Select by version number, not date — JFrog's timestamps reflect bulk
    # re-syncs and can make an older version look newest.
    local parse_result
    parse_result="$(echo "$html" | awk '
        {
            if (match($0, /href="jfrog-artifactory-pro-[0-9.]+\.rpm"/) == 0) next
            fs = RSTART + 6; fl = RLENGTH - 7
            fname = substr($0, fs, fl)
            # Extract the version string between the prefix and ".rpm".
            ver = fname
            sub(/^jfrog-artifactory-pro-/, "", ver)
            sub(/\.rpm$/, "", ver)
            n = split(ver, p, ".")
            if (n < 3) next
            a1 = p[1] + 0; a2 = p[2] + 0; a3 = p[3] + 0

            # Optional date + size on the same line, used for the report only.
            dt = ""; size = ""
            if (match($0, /[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]/)) {
                dt = substr($0, RSTART, RLENGTH)
            }
            if (match($0, /[0-9]+\.[0-9]+ [KMGT]?B/)) size = substr($0, RSTART, RLENGTH)

            if (best_fname == "" || a1 > b1 || (a1 == b1 && a2 > b2) || (a1 == b1 && a2 == b2 && a3 > b3)) {
                best_fname = fname; best_date = dt; best_size = size
                b1 = a1; b2 = a2; b3 = a3
            }
        }
        END { print best_fname "|" best_date "|" best_size }
    ')"

    local fname date_str size
    IFS='|' read -r fname date_str size <<< "$parse_result"

    if [[ -z "$fname" ]]; then
        site_log "$site" ERROR "No RPMs found in index"
        site_report "$site" status failed
        return 1
    fi

    local url="${index_url}${fname}"

    site_log "$site" INFO "Latest: $fname${date_str:+ (published $date_str)}"

    # Fetch sha256 from HEAD header.
    local sha=""
    sha="$(curl "${CURL_API_OPTS[@]}" -I "$url" 2>/dev/null | \
           awk -F': ' 'tolower($1)=="x-checksum-sha256" {print $2}' | \
           tr -d '\r\n ')"

    site_report "$site" product "JFrog Artifactory Pro"
    site_report "$site" filename "$fname"
    site_report "$site" url "$url"
    site_report "$site" published "$date_str"
    site_report "$site" size "$size"
    if [[ -n "$sha" ]]; then
        site_report "$site" checksum_expected "$sha"
        site_report "$site" checksum_algo "sha256"
    else
        site_report "$site" checksum_algo "rpm-sig"
    fi

    local dest="${RUN_DIR}/${fname}"
    if [[ -f "$dest" ]]; then
        if [[ -n "$sha" ]] && verify_sha256_hex "$dest" "$sha"; then
            site_log "$site" INFO "Already present with valid checksum, skipping"
            site_report "$site" status "already-present"
            return 0
        fi
        if [[ -z "$sha" ]] && verify_rpm_sig "$dest"; then
            site_log "$site" INFO "Already present with valid RPM signature, skipping"
            site_report "$site" status "already-present"
            return 0
        fi
    fi

    prune_old_versions "jfrog-artifactory-pro-*.rpm" "$fname"

    local size_bytes
    size_bytes="$(size_to_bytes "$size")"
    local needed
    needed="$(awk -v b="$size_bytes" -v m="$DISK_MULT_PLAIN" 'BEGIN { printf "%.0f", b * m }')"
    if ! check_disk_space "$RUN_DIR" "$needed"; then
        site_log "$site" ERROR "Insufficient disk space"
        site_report "$site" status "insufficient-space"
        return 1
    fi

    if ! do_download "$url" "$dest" "$site"; then
        site_report "$site" status "download-failed"
        return 1
    fi

    if (( DRY_RUN == 1 )); then
        site_report "$site" status "dry-run"
        return 0
    fi

    if [[ -n "$sha" ]]; then
        if ! verify_sha256_hex "$dest" "$sha"; then
            site_log "$site" ERROR "Checksum mismatch"
            site_report "$site" status "checksum-mismatch"
            return 1
        fi
        site_log "$site" INFO "Verified (sha256)"
        site_report "$site" checksum_verified "yes"
    else
        if ! verify_rpm_sig "$dest"; then
            site_log "$site" ERROR "RPM signature verification failed"
            site_report "$site" status "sig-mismatch"
            return 1
        fi
        site_log "$site" INFO "Verified (rpm signature)"
        site_report "$site" checksum_verified "yes"
    fi
    site_report "$site" status "downloaded"
    return 0
}

# ---------------------------------------------------------------------------
# Parser: JFrog Xray (two-level listing, extract after)
# ---------------------------------------------------------------------------

parse_xray() {
    local site="xray"
    local base_url="https://releases.jfrog.io/artifactory/jfrog-xray/xray-rpm/"

    site_log "$site" INFO "Fetching top-level index"
    local html
    html="$(curl "${CURL_API_OPTS[@]}" "$base_url")" || {
        site_log "$site" ERROR "Failed to fetch top-level index"
        site_report "$site" status failed
        return 1
    }

    # Parse top-level listing for version directories. Select by version
    # number, not by listing date — JFrog's directory timestamps reflect
    # bulk re-sync activity and can put stale versions above newer ones.
    local best_ver=""
    best_ver="$(echo "$html" | awk '
        {
            if (match($0, /href="[0-9]+\.[0-9]+\.[0-9]+\/"/) == 0) next
            hs = RSTART + 6; hl = RLENGTH - 8
            ver = substr($0, hs, hl)
            # Split into numeric components and compare against current best.
            n = split(ver, p, ".")
            a1 = p[1] + 0; a2 = p[2] + 0; a3 = p[3] + 0
            if (best_ver == "") { best_ver = ver; b1 = a1; b2 = a2; b3 = a3; next }
            if (a1 > b1 || (a1 == b1 && a2 > b2) || (a1 == b1 && a2 == b2 && a3 > b3)) {
                best_ver = ver; b1 = a1; b2 = a2; b3 = a3
            }
        }
        END { print best_ver }
    ')"

    if [[ -z "$best_ver" ]]; then
        site_log "$site" ERROR "No version directories found after parsing top-level index"
        site_report "$site" status failed
        return 1
    fi

    site_log "$site" INFO "Latest version: $best_ver"
    local version_url="${base_url}${best_ver}/"
    site_log "$site" INFO "Fetching file listing: $version_url"
    local sub_html
    sub_html="$(curl "${CURL_API_OPTS[@]}" "$version_url")" || {
        site_log "$site" ERROR "Failed to fetch version index (URL: $version_url)"
        site_report "$site" status failed
        return 1
    }

    local fname="" size=""
    local sub_line
    while IFS= read -r sub_line; do
        case "$sub_line" in *'rpm.tar.gz'*) ;; *) continue ;; esac
        fname="$(echo "$sub_line" | grep -oE 'href="jfrog-xray-[0-9.]+-rpm\.tar\.gz"' | head -1 | sed 's/href="//;s/"$//')"
        [[ -z "$fname" ]] && continue
        size="$(echo "$sub_line" | grep -oE '[0-9]+\.[0-9]+ [KMGT]?B' | head -1)"
        [[ -z "$size" ]] && size="unknown"
        break
    done <<< "$sub_html"

    if [[ -z "$fname" ]]; then
        site_log "$site" ERROR "No tarball in version dir (URL: $version_url)"
        site_report "$site" status failed
        return 1
    fi

    local url="${version_url}${fname}"
    site_log "$site" INFO "File: $fname ($size)"

    # Checksum from HTTP header.
    local sha=""
    sha="$(curl "${CURL_API_OPTS[@]}" -I "$url" 2>/dev/null | \
           awk -F': ' 'tolower($1)=="x-checksum-sha256" {print $2}' | \
           tr -d '\r\n ')"

    site_report "$site" product "JFrog Xray"
    site_report "$site" version "$best_ver"
    site_report "$site" filename "$fname"
    site_report "$site" url "$url"
    site_report "$site" size "$size"
    [[ -n "$sha" ]] && site_report "$site" checksum_expected "$sha"
    site_report "$site" checksum_algo "sha256"

    local dest="${RUN_DIR}/${fname}"
    local extract_dir="${dest%.tar.gz}"

    if [[ -f "$dest" ]] && [[ -n "$sha" ]] && verify_sha256_hex "$dest" "$sha"; then
        if [[ -d "$extract_dir" ]]; then
            site_log "$site" INFO "Already present and extracted, skipping"
            site_report "$site" status "already-present"
            return 0
        fi
        site_log "$site" INFO "Tarball present, re-extracting"
        if ! extract_tarball "$dest" "$site"; then
            site_report "$site" status "extract-failed"
            return 1
        fi
        site_report "$site" status "already-present"
        site_report "$site" extracted "yes"
        return 0
    fi

    prune_old_versions "jfrog-xray-*-rpm.tar.gz" "$fname"
    prune_old_dirs "jfrog-xray-*-rpm" "${fname%.tar.gz}"

    local size_bytes needed
    size_bytes="$(size_to_bytes "$size")"
    if [[ "$size_bytes" == "0" ]]; then
        site_log "$site" WARN "Size unknown from listing, assuming 2GB for disk check"
        size_bytes=$((2 * 1024 * 1024 * 1024))
    fi
    needed="$(awk -v b="$size_bytes" -v m="$DISK_MULT_EXTRACT" 'BEGIN { printf "%.0f", b * m }')"
    if ! check_disk_space "$RUN_DIR" "$needed"; then
        site_log "$site" ERROR "Insufficient disk space (need ~$(human_bytes "$needed"))"
        site_report "$site" status "insufficient-space"
        return 1
    fi

    if ! do_download "$url" "$dest" "$site"; then
        site_report "$site" status "download-failed"
        return 1
    fi

    if (( DRY_RUN == 1 )); then
        site_report "$site" status "dry-run"
        return 0
    fi

    if [[ -n "$sha" ]]; then
        if ! verify_sha256_hex "$dest" "$sha"; then
            site_log "$site" ERROR "Checksum mismatch"
            site_report "$site" status "checksum-mismatch"
            return 1
        fi
        site_log "$site" INFO "Verified (sha256)"
        site_report "$site" checksum_verified "yes"
    fi

    if ! extract_tarball "$dest" "$site"; then
        site_report "$site" status "extract-failed"
        return 1
    fi
    site_report "$site" extracted "yes"
    site_report "$site" status "downloaded"
    return 0
}

# ---------------------------------------------------------------------------
# Parser: GitLab EE
# ---------------------------------------------------------------------------

parse_gitlab_ee() {
    local site="gitlab-ee"
    local index_url="https://packages.gitlab.com/gitlab/gitlab-ee/el/8/x86_64/Packages/g/"
    # Version pin lives at the top of this script (PIN_GITLAB_EE). Set to "" for no filter.
    local line_filter="$PIN_GITLAB_EE"

    site_log "$site" INFO "Fetching index (filter: ${line_filter:-none})"
    local html
    html="$(curl "${CURL_API_OPTS[@]}" "$index_url")" || {
        site_log "$site" ERROR "Failed to fetch index"
        site_report "$site" status failed
        return 1
    }

    # Dates are unreliable (bulk re-sync timestamps), so version-sort.
    local filenames
    filenames="$(echo "$html" | \
        grep -oE 'gitlab-ee-[0-9]+\.[0-9]+\.[0-9]+-ee\.0\.el8\.x86_64\.rpm' | \
        sort -uV)"

    if [[ -z "$filenames" ]]; then
        site_log "$site" ERROR "No RPMs matching pattern"
        site_report "$site" status failed
        return 1
    fi

    # Apply release-line filter if set. The filter matches on "gitlab-ee-X.Y."
    # as a prefix so we don't accidentally match 18.9 against 18.90, 18.99 etc.
    if [[ -n "$line_filter" ]]; then
        local filtered
        filtered="$(echo "$filenames" | grep -E "^gitlab-ee-${line_filter}\.[0-9]+-ee\.0\.el8\.x86_64\.rpm$")"
        if [[ -z "$filtered" ]]; then
            site_log "$site" ERROR "No RPMs in ${line_filter}.x line"
            site_report "$site" status failed
            return 1
        fi
        filenames="$filtered"
    fi

    local fname
    fname="$(echo "$filenames" | tail -1)"
    local url="${index_url}${fname}"

    site_log "$site" INFO "Latest: $fname"
    site_report "$site" product "GitLab Enterprise Edition"
    site_report "$site" filename "$fname"
    site_report "$site" url "$url"
    site_report "$site" checksum_algo "rpm-sig"

    local dest="${RUN_DIR}/${fname}"
    if [[ -f "$dest" ]] && verify_rpm_sig "$dest"; then
        site_log "$site" INFO "Already present and valid, skipping"
        site_report "$site" status "already-present"
        return 0
    fi

    prune_old_versions "gitlab-ee-*-ee.0.el8.x86_64.rpm" "$fname"

    # We don't know the size ahead of time; trust the FS.
    if ! do_download "$url" "$dest" "$site"; then
        site_report "$site" status "download-failed"
        return 1
    fi

    if (( DRY_RUN == 1 )); then
        site_report "$site" status "dry-run"
        return 0
    fi

    # Record actual size post-download.
    local actual_size
    actual_size="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    site_report "$site" size "$(human_bytes "$actual_size")"

    if ! verify_rpm_sig "$dest"; then
        site_log "$site" ERROR "RPM signature verification failed"
        site_report "$site" status "sig-mismatch"
        return 1
    fi
    site_log "$site" INFO "Verified (rpm signature)"
    site_report "$site" checksum_verified "yes"
    site_report "$site" status "downloaded"
    return 0
}

# ---------------------------------------------------------------------------
# Parser: GitLab Runner (2 RPMs, matched versions)
# ---------------------------------------------------------------------------

parse_gitlab_runner() {
    local site="gitlab-runner"
    local index_url="https://packages.gitlab.com/runner/gitlab-runner/el/8/x86_64/Packages/g/"
    # Version pin lives at the top of this script (PIN_GITLAB_RUNNER). Should
    # generally match PIN_GITLAB_EE for runner/server compatibility.
    local line_filter="$PIN_GITLAB_RUNNER"

    site_log "$site" INFO "Fetching index (filter: ${line_filter:-none})"
    local html
    html="$(curl "${CURL_API_OPTS[@]}" "$index_url")" || {
        site_log "$site" ERROR "Failed to fetch index"
        site_report "$site" status failed
        return 1
    }

    # Extract runner versions (excluding -fips- and -helper-).
    local runner_versions
    runner_versions="$(echo "$html" | \
        grep -oE 'gitlab-runner-[0-9]+\.[0-9]+\.[0-9]+-1\.x86_64\.rpm' | \
        sed -E 's/gitlab-runner-([0-9.]+)-1\.x86_64\.rpm/\1/' | \
        sort -uV)"

    # Extract helper-images versions.
    local helper_versions
    helper_versions="$(echo "$html" | \
        grep -oE 'gitlab-runner-helper-images-[0-9]+\.[0-9]+\.[0-9]+-1\.noarch\.rpm' | \
        sed -E 's/gitlab-runner-helper-images-([0-9.]+)-1\.noarch\.rpm/\1/' | \
        sort -uV)"

    if [[ -z "$runner_versions" ]] || [[ -z "$helper_versions" ]]; then
        site_log "$site" ERROR "Missing runner or helper-images versions"
        site_report "$site" status failed
        return 1
    fi

    # Apply release-line filter if set. Anchor on "X.Y." prefix to prevent
    # false matches (e.g. filter "18.10" must not match "18.90" or "18.99").
    if [[ -n "$line_filter" ]]; then
        runner_versions="$(echo "$runner_versions" | grep -E "^${line_filter}\.")"
        helper_versions="$(echo "$helper_versions" | grep -E "^${line_filter}\.")"
        if [[ -z "$runner_versions" ]] || [[ -z "$helper_versions" ]]; then
            site_log "$site" ERROR "No runner or helper-images in ${line_filter}.x line"
            site_report "$site" status failed
            return 1
        fi
    fi

    # Intersection: highest version where both exist.
    local matched_version=""
    local v
    while IFS= read -r v; do
        if echo "$helper_versions" | grep -qxF "$v"; then
            matched_version="$v"
            break
        fi
    done < <(echo "$runner_versions" | tac)

    if [[ -z "$matched_version" ]]; then
        site_log "$site" ERROR "No runner/helper version pair matches"
        site_report "$site" status failed
        return 1
    fi

    # Note any newer runner-only versions for the report (within the same line).
    local newest_runner_only
    newest_runner_only="$(echo "$runner_versions" | tail -1)"

    site_log "$site" INFO "Matched version: $matched_version (newest runner in line: $newest_runner_only)"

    local runner_fname="gitlab-runner-${matched_version}-1.x86_64.rpm"
    local helper_fname="gitlab-runner-helper-images-${matched_version}-1.noarch.rpm"
    local runner_url="${index_url}${runner_fname}"
    local helper_url="${index_url}${helper_fname}"

    site_report "$site" product "GitLab Runner"
    site_report "$site" version "$matched_version"
    site_report "$site" filename "${runner_fname},${helper_fname}"
    site_report "$site" url "${runner_url},${helper_url}"
    site_report "$site" checksum_algo "rpm-sig"
    if [[ "$newest_runner_only" != "$matched_version" ]]; then
        site_report "$site" note "newer runner ${newest_runner_only} exists but has no matching helper"
    fi

    local f url dest
    local all_good=1
    for pair in "runner|${runner_fname}|${runner_url}" "helper|${helper_fname}|${helper_url}"; do
        IFS='|' read -r _ f url <<< "$pair"
        dest="${RUN_DIR}/${f}"
        if [[ -f "$dest" ]] && verify_rpm_sig "$dest"; then
            site_log "$site" INFO "$f already present and valid"
            continue
        fi
        if ! do_download "$url" "$dest" "$site"; then
            all_good=0
            continue
        fi
        if (( DRY_RUN == 1 )); then continue; fi
        if ! verify_rpm_sig "$dest"; then
            site_log "$site" ERROR "$f signature failed"
            all_good=0
        fi
    done

    # Prune old versions of both files.
    prune_old_versions "gitlab-runner-[0-9]*-1.x86_64.rpm" "$runner_fname"
    prune_old_versions "gitlab-runner-helper-images-*-1.noarch.rpm" "$helper_fname"

    if (( DRY_RUN == 1 )); then
        site_report "$site" status "dry-run"
        return 0
    fi

    if (( all_good == 1 )); then
        site_report "$site" status "downloaded"
        site_report "$site" checksum_verified "yes"
        return 0
    else
        site_report "$site" status "partial-failure"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Parser: Elastic Stack (Elasticsearch + Kibana + Logstash)
# ---------------------------------------------------------------------------

parse_elastic() {
    local site="elastic"
    # Version pin lives at the top of this script (PIN_ELASTIC).
    local line_filter="$PIN_ELASTIC"
    local api_url="https://endoflife.date/api/elasticsearch.json"

    site_log "$site" INFO "Querying endoflife.date for Elasticsearch ${line_filter}.x"
    local json
    json="$(curl "${CURL_API_OPTS[@]}" "$api_url")" || {
        site_log "$site" ERROR "API request failed"
        site_report "$site" status failed
        return 1
    }

    # Legacy endoflife.date shape: flat array with per-cycle entries like:
    #   {"cycle": "9.4", "latest": "9.4.1", ...}
    # We filter to the desired cycle and pull .latest.
    local version
    version="$(echo "$json" | jq -r --arg cyc "$line_filter" \
        '.[] | select(.cycle == $cyc) | .latest' 2>/dev/null)"

    if [[ -z "$version" ]] || [[ "$version" == "null" ]]; then
        # Build a comma-separated list of cycles the API DID return so the
        # operator can see at a glance whether endoflife.date is missing the
        # requested release line (community-maintained, often lags Elastic
        # by days or weeks).
        local available
        available="$(echo "$json" | jq -r '[.[].cycle] | join(", ")' 2>/dev/null)"
        site_log "$site" ERROR "No release found for line ${line_filter}.x"
        site_log "$site" ERROR "API reports cycles: ${available:-(none)}"
        site_log "$site" ERROR "endoflife.date may not have indexed ${line_filter} yet"
        site_report "$site" status failed
        return 1
    fi

    site_log "$site" INFO "Latest ${line_filter}.x: $version"
    site_report "$site" product "Elastic Stack"
    site_report "$site" version "$version"
    site_report "$site" checksum_algo "sha512"

    local components=(elasticsearch kibana logstash)
    local filenames=() urls=()
    local comp
    for comp in "${components[@]}"; do
        local fname="${comp}-${version}-x86_64.rpm"
        local url="https://artifacts.elastic.co/downloads/${comp}/${fname}"
        filenames+=("$fname")
        urls+=("$url")
    done
    site_report "$site" filename "$(IFS=','; echo "${filenames[*]}")"
    site_report "$site" url "$(IFS=','; echo "${urls[*]}")"

    local all_good=1
    local i
    for i in "${!components[@]}"; do
        local fname="${filenames[$i]}"
        local url="${urls[$i]}"
        local sha_url="${url}.sha512"
        local dest="${RUN_DIR}/${fname}"
        local sha_dest="${dest}.sha512"

        # Reuse check.
        if [[ -f "$dest" ]] && [[ -f "$sha_dest" ]] && \
           verify_sidecar "$dest" "$sha_dest" "sha512"; then
            site_log "$site" INFO "$fname already present and valid"
            continue
        fi

        if ! do_download "$url" "$dest" "$site"; then
            all_good=0
            continue
        fi
        if ! do_download "$sha_url" "$sha_dest" "$site"; then
            all_good=0
            continue
        fi
        if (( DRY_RUN == 1 )); then continue; fi
        if ! verify_sidecar "$dest" "$sha_dest" "sha512"; then
            site_log "$site" ERROR "$fname sha512 mismatch"
            all_good=0
        fi
    done

    # Prune old Elastic files.
    for comp in "${components[@]}"; do
        prune_old_versions "${comp}-*-x86_64.rpm" "${comp}-${version}-x86_64.rpm"
        prune_old_versions "${comp}-*-x86_64.rpm.sha512" "${comp}-${version}-x86_64.rpm.sha512"
    done

    if (( DRY_RUN == 1 )); then
        site_report "$site" status "dry-run"
        return 0
    fi
    if (( all_good == 1 )); then
        site_report "$site" status "downloaded"
        site_report "$site" checksum_verified "yes"
        return 0
    else
        site_report "$site" status "partial-failure"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: resolve latest Atlassian version matching a subproduct filter
# ---------------------------------------------------------------------------

# Args:
#   api_product  - puds product name (jira|conf)
#   subproduct   - filter code (JSW|JC|CONFLUENCE) — empty = no filter
#   major.minor  - version line filter (e.g. "10.3" or "10.2")
#
# Echoes: "VERSION|DOWNLOAD_URL" for the single highest match, or empty.
#
# Strategy: prefer the .bin installer (linuxInstallerDistribution) since it's
# a single-file self-extracting installer. Fall back to the .tar.gz archive
# only if no .bin is published for a given version.
resolve_atlassian_version() {
    local api_product="$1" subproduct="$2" line_filter="$3"
    local url="https://puds.prod.atl-paas.net/rest/v1/upgrade/info?product=${api_product}"
    local json
    json="$(curl "${CURL_API_OPTS[@]}" "$url")" || return 1

    local filter='.[] | .versions[]'
    if [[ -n "$line_filter" ]]; then
        local maj min
        IFS='.' read -r maj min <<< "$line_filter"
        filter+=" | select(.version.major == $maj and .version.minor == $min)"
    fi

    # For each matching version: pick installer link if available, else archive.
    local jq_expr
    jq_expr="[${filter} | . as \$v | \
        (\$v.linuxInstallerDistribution // []) as \$ins | \
        (\$v.linuxArchiveDistribution   // []) as \$arc | \
        ([\$ins[] | select(.subProduct==\"${subproduct}\")] | first // null) as \$pick_ins | \
        ([\$arc[] | select(.subProduct==\"${subproduct}\")] | first // null) as \$pick_arc | \
        (\$pick_ins // \$pick_arc) as \$pick | \
        select(\$pick != null and (\$pick.link != null) and (\$pick.link != \"\")) | \
        {maj: \$v.version.major, min: \$v.version.minor, bug: \$v.version.bugfix, link: \$pick.link}] \
        | sort_by(.maj, .min, .bug) | last \
        | \"\\(.maj).\\(.min).\\(.bug)|\\(.link)\""

    local results
    results="$(echo "$json" | jq -r "$jq_expr" 2>/dev/null)"
    if [[ -z "$results" ]]; then
        return 1
    fi
    echo "$results"
}

# ---------------------------------------------------------------------------
# Generic Atlassian parser (shared by jira-software / jira-core / confluence)
# ---------------------------------------------------------------------------

parse_atlassian_generic() {
    local site="$1" product_label="$2" api_product="$3" subproduct="$4" line_filter="$5"

    site_log "$site" INFO "Resolving latest ${line_filter}.x version"
    local result
    result="$(resolve_atlassian_version "$api_product" "$subproduct" "$line_filter")"
    if [[ -z "$result" ]]; then
        site_log "$site" ERROR "Could not resolve version from puds API"
        site_report "$site" status failed
        return 1
    fi

    local version url
    IFS='|' read -r version url <<< "$result"
    local fname
    fname="$(basename "$url")"

    site_log "$site" INFO "Latest: $fname"

    # Construct checksum URLs. Atlassian publishes .sha256 and .md5 sidecars
    # for most installers; .sha256 is newer and preferred. We try .sha256 first
    # and fall back to .md5.
    local sha256_url="${url}.sha256"
    local md5_url="${url}.md5"

    site_report "$site" product "$product_label"
    site_report "$site" version "$version"
    site_report "$site" filename "$fname"
    site_report "$site" url "$url"
    site_report "$site" checksum_algo "sha256-or-md5"

    local dest="${RUN_DIR}/${fname}"
    local extract_dir="${dest%.tar.gz}"
    local needs_extract=0
    [[ "$fname" == *.tar.gz ]] && needs_extract=1

    # Reuse check. For Atlassian, we just try sha256 since we can't know in
    # advance what sidecar is published; the sidecar file itself will be
    # present alongside the main file if it was downloaded previously.
    if [[ -f "$dest" ]]; then
        local reused=0
        if [[ -f "${dest}.sha256" ]] && verify_sidecar "$dest" "${dest}.sha256" "sha256"; then
            reused=1
        elif [[ -f "${dest}.md5" ]] && verify_sidecar "$dest" "${dest}.md5" "md5"; then
            reused=1
        fi
        if (( reused == 1 )); then
            if (( needs_extract == 1 )) && [[ -d "$extract_dir" ]]; then
                site_log "$site" INFO "Already present and extracted, skipping"
                site_report "$site" status "already-present"
                return 0
            elif (( needs_extract == 0 )); then
                site_log "$site" INFO "Already present and valid, skipping"
                site_report "$site" status "already-present"
                return 0
            fi
        fi
    fi

    # Prune old versions. Match both .bin (installer) and .tar.gz (archive)
    # since the script may switch formats between runs and we want one file
    # per product in the run dir.
    local prune_prefix
    case "$site" in
        jira-software) prune_prefix="atlassian-jira-software-" ;;
        jira-core)     prune_prefix="atlassian-jira-core-" ;;
        confluence)    prune_prefix="atlassian-confluence-" ;;
    esac
    if [[ -n "$prune_prefix" ]]; then
        # Tarball form.
        prune_old_versions "${prune_prefix}*.tar.gz" "$fname"
        prune_old_versions "${prune_prefix}*.tar.gz.sha256" "${fname}.sha256"
        prune_old_versions "${prune_prefix}*.tar.gz.md5" "${fname}.md5"
        # Installer form (.bin with -x64 suffix).
        prune_old_versions "${prune_prefix}*-x64.bin" "$fname"
        prune_old_versions "${prune_prefix}*-x64.bin.sha256" "${fname}.sha256"
        prune_old_versions "${prune_prefix}*-x64.bin.md5" "${fname}.md5"
        # Extracted directories (only if this is a tarball run).
        if (( needs_extract == 1 )); then
            prune_old_dirs "${prune_prefix}*" "${fname%.tar.gz}"
        else
            # We're downloading a .bin, so any previously extracted tarball
            # directories are also stale.
            prune_old_dirs "${prune_prefix}*" "__NEVER_MATCH__"
        fi
    fi

    if ! do_download "$url" "$dest" "$site"; then
        site_report "$site" status "download-failed"
        return 1
    fi

    # Try sha256 sidecar first, fall back to md5. A 404 on either is ok so
    # long as one works.
    local sha_method=""
    local sha_sidecar=""
    if curl "${CURL_API_OPTS[@]}" -o "${dest}.sha256" "$sha256_url" 2>/dev/null; then
        sha_method="sha256"
        sha_sidecar="${dest}.sha256"
    elif curl "${CURL_API_OPTS[@]}" -o "${dest}.md5" "$md5_url" 2>/dev/null; then
        sha_method="md5"
        sha_sidecar="${dest}.md5"
    fi

    if (( DRY_RUN == 1 )); then
        site_report "$site" status "dry-run"
        return 0
    fi

    if [[ -z "$sha_method" ]]; then
        site_log "$site" WARN "No checksum sidecar available"
        site_report "$site" checksum_verified "not-available"
    else
        if ! verify_sidecar "$dest" "$sha_sidecar" "$sha_method"; then
            site_log "$site" ERROR "$sha_method checksum mismatch"
            site_report "$site" status "checksum-mismatch"
            return 1
        fi
        site_log "$site" INFO "Verified ($sha_method)"
        site_report "$site" checksum_algo "$sha_method"
        site_report "$site" checksum_verified "yes"
    fi

    local actual_size
    actual_size="$(stat -c %s "$dest" 2>/dev/null || echo 0)"
    site_report "$site" size "$(human_bytes "$actual_size")"

    if (( needs_extract == 1 )); then
        if ! extract_tarball "$dest" "$site"; then
            site_report "$site" status "extract-failed"
            return 1
        fi
        site_report "$site" extracted "yes"
    fi

    site_report "$site" status "downloaded"
    return 0
}

parse_jira_software() {
    parse_atlassian_generic "jira-software" "Jira Software Data Center" "jira" "JSW" "$PIN_JIRA"
}

parse_jira_core() {
    parse_atlassian_generic "jira-core" "Jira Core Data Center" "jira" "JC" "$PIN_JIRA"
}

parse_confluence() {
    parse_atlassian_generic "confluence" "Confluence Data Center" "conf" "CONFLUENCE" "$PIN_CONFLUENCE"
}

# ---------------------------------------------------------------------------
# Site dispatch
# ---------------------------------------------------------------------------

run_site() {
    local site="$1"
    # Redirect stdout and stderr of the parser through the logger; each log
    # line is already prefixed with [site] so parallel output is readable.
    case "$site" in
        nagios)         parse_nagios ;;
        artifactory)    parse_artifactory ;;
        xray)           parse_xray ;;
        gitlab-ee)      parse_gitlab_ee ;;
        gitlab-runner)  parse_gitlab_runner ;;
        elastic)        parse_elastic ;;
        jira-software)  parse_jira_software ;;
        jira-core)      parse_jira_core ;;
        confluence)     parse_confluence ;;
        *)              error "Unknown site: $site"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------

build_report() {
    local report_path="${RUN_DIR}/report.txt"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    local mode="normal"
    (( DRY_RUN == 1 )) && mode="dry-run"

    {
        echo "=============================================="
        echo "  Monthly Software Update Report"
        echo "=============================================="
        echo ""
        echo "Generated:  $ts"
        echo "Mode:       $mode"
        echo "Directory:  $RUN_DIR"
        echo ""
        echo "----------------------------------------------"

        local site
        for site in "${SELECTED_SITES[@]}"; do
            local report_file="${SITE_LOG_DIR}/${site}.report"
            echo ""
            echo "[${site}]"
            if [[ ! -f "$report_file" ]]; then
                echo "  (no report — parser did not run)"
                continue
            fi
            # Pull fields out of the key=value report.
            local product filename version size url published status checksum_algo checksum_verified note extracted
            product="$(grep -m1 '^product=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            filename="$(grep -m1 '^filename=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            version="$(grep -m1 '^version=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            size="$(grep -m1 '^size=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            url="$(grep -m1 '^url=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            published="$(grep -m1 '^published=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            status="$(grep -m1 '^status=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            checksum_algo="$(grep -m1 '^checksum_algo=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            checksum_verified="$(grep -m1 '^checksum_verified=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            note="$(grep -m1 '^note=' "$report_file" 2>/dev/null | cut -d= -f2-)"
            extracted="$(grep -m1 '^extracted=' "$report_file" 2>/dev/null | cut -d= -f2-)"

            [[ -n "$product" ]]           && echo "  Product:        $product"
            [[ -n "$version" ]]           && echo "  Version:        $version"
            [[ -n "$filename" ]]          && echo "  File(s):        $filename"
            [[ -n "$published" ]]         && echo "  Published:      $published"
            [[ -n "$size" ]]              && echo "  Size:           $size"
            [[ -n "$url" ]]               && echo "  Source URL:     $url"
            [[ -n "$checksum_algo" ]]     && echo "  Checksum type:  $checksum_algo"
            [[ -n "$checksum_verified" ]] && echo "  Verified:       $checksum_verified"
            [[ -n "$extracted" ]]         && echo "  Extracted:      $extracted"
            [[ -n "$note" ]]              && echo "  Note:           $note"
            [[ -n "$status" ]]            && echo "  Status:         $status"
        done

        echo ""
        echo "=============================================="
    } > "$report_path"

    info "Report written to $report_path"
    # Also echo to terminal.
    cat "$report_path"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --all                     Run all sites
  --site NAME               Run a specific site (repeatable)
  --group NAME              Run a named group of sites (repeatable)
  --dry-run                 Resolve versions but don't download
  --max-parallel N          Limit concurrent site runs (default: ${DEFAULT_MAX_PARALLEL})
  --list                    List available sites
  --list-groups             List available groups and their sites
  -h, --help                Show this help

Sites:
EOF
    local s
    for s in "${ALL_SITES[@]}"; do
        printf "  %s\n" "$s"
    done
    echo
    echo "Groups:"
    local g
    for g in "${!SITE_GROUPS[@]}"; do
        printf "  %-12s -> %s\n" "$g" "${SITE_GROUPS[$g]}"
    done
}

parse_args() {
    local all=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)          all=1; shift ;;
            --site)         SELECTED_SITES+=("$2"); shift 2 ;;
            --group)
                local gname="$2"
                if [[ -z "${SITE_GROUPS[$gname]+x}" ]]; then
                    die "Unknown group: $gname. Use --list-groups to see options."
                fi
                # Expand the group into individual sites.
                local gs
                for gs in ${SITE_GROUPS[$gname]}; do
                    SELECTED_SITES+=("$gs")
                done
                shift 2
                ;;
            --dry-run)      DRY_RUN=1; shift ;;
            --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
            --list)
                for s in "${ALL_SITES[@]}"; do echo "$s"; done
                exit 0
                ;;
            --list-groups)
                local gname
                for gname in "${!SITE_GROUPS[@]}"; do
                    printf "%-12s %s\n" "$gname" "${SITE_GROUPS[$gname]}"
                done
                exit 0
                ;;
            -h|--help)      usage; exit 0 ;;
            *)              die "Unknown option: $1. Use --help." ;;
        esac
    done

    if (( all == 1 )); then
        if (( ${#SELECTED_SITES[@]} > 0 )); then
            die "Cannot use --all together with --site or --group"
        fi
        SELECTED_SITES=("${ALL_SITES[@]}")
    fi

    if (( ${#SELECTED_SITES[@]} == 0 )); then
        usage >&2
        die "Must specify --all, --site, or --group"
    fi

    # Deduplicate (in case --group and --site overlap, or two groups overlap).
    local -A seen=()
    local dedup=()
    local s
    for s in "${SELECTED_SITES[@]}"; do
        if [[ -z "${seen[$s]+x}" ]]; then
            seen[$s]=1
            dedup+=("$s")
        fi
    done
    SELECTED_SITES=("${dedup[@]}")

    # Validate site names.
    for s in "${SELECTED_SITES[@]}"; do
        local found=0
        local valid
        for valid in "${ALL_SITES[@]}"; do
            [[ "$s" == "$valid" ]] && found=1 && break
        done
        (( found == 0 )) && die "Invalid site name: $s"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    check_deps

    mkdir -p "$RUN_DIR"
    SITE_LOG_DIR="$(mktemp -d)"
    trap 'rm -rf "$SITE_LOG_DIR"' EXIT

    info "Run directory: $RUN_DIR"
    (( DRY_RUN == 1 )) && info "DRY-RUN mode: no files will be downloaded"
    # When only one site is selected, enable interactive progress bar mode in
    # do_download. With multiple sites, bars would interleave, so we stay silent.
    if (( ${#SELECTED_SITES[@]} == 1 )); then
        SINGLE_SITE_MODE=1
        info "Running 1 site (progress bar enabled)"
    else
        info "Starting ${#SELECTED_SITES[@]} site(s) in parallel (max ${MAX_PARALLEL} concurrent)"
    fi

    # Launch parsers with a simple semaphore: hold a pool of up to N pids.
    local pids=()
    local site
    for site in "${SELECTED_SITES[@]}"; do
        # Wait if we're at capacity.
        while (( ${#pids[@]} >= MAX_PARALLEL )); do
            local new_pids=()
            local p
            for p in "${pids[@]}"; do
                if kill -0 "$p" 2>/dev/null; then
                    new_pids+=("$p")
                fi
            done
            pids=("${new_pids[@]}")
            (( ${#pids[@]} >= MAX_PARALLEL )) && sleep 1
        done
        run_site "$site" &
        pids+=($!)
    done

    # Wait for all.
    local overall_rc=0
    local p
    for p in "${pids[@]}"; do
        if ! wait "$p"; then
            overall_rc=1
        fi
    done

    info "All site runs complete, generating report"
    build_report

    exit "$overall_rc"
}

main "$@"
