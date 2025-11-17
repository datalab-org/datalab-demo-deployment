#!/bin/bash
# Verify Borg backup on remote server and write metric to Prometheus textfile
#
# This script SSHs to the remote server and checks the actual last backup timestamp
# from the repository, ensuring the backup really made it to the remote server.
#
# Usage: borg_write_metric.sh /path/to/output.prom
#
# Environment variables:
#   BORG_REPO: Repository path (e.g., user@rsync.net:backup/repo)
#   BORG_REPO_USER: SSH user (optional, extracted from BORG_REPO if not set)
#   BORG_REPO_HOST: SSH host (optional, extracted from BORG_REPO if not set)
#   BORG_REPO_PATH: Remote path (optional, extracted from BORG_REPO if not set)

set -e

OUTPUT_FILE="${1:-/var/lib/prometheus/node-exporter/borg.prom}"
HOSTNAME="${HOSTNAME:-$(hostname)}"
REPO_PATH="${BORG_REPO:-unknown}"

# Parse the BORG_REPO to extract SSH details
# Format: user@host:path or ssh://user@host/path
if [[ "$REPO_PATH" =~ ^([^@]+)@([^:]+):(.+)$ ]]; then
    BORG_REPO_USER="${BORG_REPO_USER:-${BASH_REMATCH[1]}}"
    BORG_REPO_HOST="${BORG_REPO_HOST:-${BASH_REMATCH[2]}}"
    BORG_REPO_PATH="${BORG_REPO_PATH:-${BASH_REMATCH[3]}}"
elif [[ "$REPO_PATH" =~ ^ssh://([^@]+)@([^/]+)/(.+)$ ]]; then
    BORG_REPO_USER="${BORG_REPO_USER:-${BASH_REMATCH[1]}}"
    BORG_REPO_HOST="${BORG_REPO_HOST:-${BASH_REMATCH[2]}}"
    BORG_REPO_PATH="${BORG_REPO_PATH:-${BASH_REMATCH[3]}}"
else
    echo "Error: Could not parse BORG_REPO. Expected format: user@host:path"
    exit 1
fi

echo "Checking backup on ${BORG_REPO_HOST}:${BORG_REPO_PATH}..."

# Get repository info from the remote server
# Pipe BORG_PASSPHRASE via stdin since rsync.net's restricted shell
# doesn't preserve environment variables
if [[ -z "$BORG_PASSPHRASE" ]]; then
    echo "Error: BORG_PASSPHRASE environment variable not set"
    exit 1
fi

echo "Checking backup on ${BORG_REPO_HOST}:${BORG_REPO_PATH}..."

# Echo the passphrase into the SSH command so borg can read it
BORG_INFO_OUTPUT=$(echo "$BORG_PASSPHRASE" | ssh "${BORG_REPO_USER}@${BORG_REPO_HOST}" \
    "BORG_PASSPHRASE=\$(cat) borg info --last 1 --json '${BORG_REPO_PATH}'" 2>&1)

SSH_EXIT_CODE=$?

if [[ $SSH_EXIT_CODE -ne 0 ]] || [[ -z "$BORG_INFO_OUTPUT" ]]; then
    echo "Error: Failed to get info from remote repository (exit code: $SSH_EXIT_CODE)"
    echo "Output: $BORG_INFO_OUTPUT"
    exit 1
fi

echo "Got output, parsing JSON..."

# Parse JSON to get archive timestamp and stats
# With --last 1, we get info about the most recent archive
if command -v jq &> /dev/null; then
    # Get the archive timestamp (this is when the backup completed)
    ARCHIVE_TIME=$(echo "$BORG_INFO_OUTPUT" | jq -r '.archives[0].start // empty')
    TOTAL_SIZE=$(echo "$BORG_INFO_OUTPUT" | jq -r '.cache.stats.total_size // 0')
    TOTAL_CSIZE=$(echo "$BORG_INFO_OUTPUT" | jq -r '.cache.stats.total_csize // 0')
    UNIQUE_SIZE=$(echo "$BORG_INFO_OUTPUT" | jq -r '.cache.stats.unique_size // 0')
    UNIQUE_CSIZE=$(echo "$BORG_INFO_OUTPUT" | jq -r '.cache.stats.unique_csize // 0')
    TOTAL_CHUNKS=$(echo "$BORG_INFO_OUTPUT" | jq -r '.cache.stats.total_chunks // 0')
else
    # Fallback: extract start field from the first archive
    ARCHIVE_TIME=$(echo "$BORG_INFO_OUTPUT" | grep -o '"start"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    # Without jq, we'll skip the stats
    TOTAL_SIZE=0
    TOTAL_CSIZE=0
    UNIQUE_SIZE=0
    UNIQUE_CSIZE=0
    TOTAL_CHUNKS=0
fi

if [[ -z "$ARCHIVE_TIME" ]]; then
    echo "Error: Could not determine archive timestamp"
    exit 1
fi

LAST_MODIFIED="$ARCHIVE_TIME"

# Convert ISO timestamp to Unix timestamp
# last_modified format: "2025-11-16T17:27:24.000000"
if command -v date &> /dev/null; then
    # GNU date or BSD date - handle both formats
    TIMESTAMP=$(date -d "${LAST_MODIFIED}" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${LAST_MODIFIED%.*}" +%s 2>/dev/null)
else
    echo "Error: date command not available"
    exit 1
fi

if [[ -z "$TIMESTAMP" ]]; then
    echo "Error: Failed to parse timestamp: $LAST_MODIFIED"
    exit 1
fi

# Calculate age in seconds
CURRENT_TIME=$(date +%s)
AGE_SECONDS=$((CURRENT_TIME - TIMESTAMP))

# Calculate compression ratio if we have the stats
if [[ "$TOTAL_CSIZE" -gt 0 ]]; then
    COMPRESSION_RATIO=$(awk "BEGIN {printf \"%.2f\", $TOTAL_SIZE / $TOTAL_CSIZE}")
else
    COMPRESSION_RATIO=0
fi

echo "✓ Last modified: $LAST_MODIFIED (${AGE_SECONDS}s ago)"
if [[ "$TOTAL_SIZE" -gt 0 ]]; then
    echo "  Total size: $(numfmt --to=iec $TOTAL_SIZE 2>/dev/null || echo $TOTAL_SIZE) (compressed: $(numfmt --to=iec $TOTAL_CSIZE 2>/dev/null || echo $TOTAL_CSIZE))"
    echo "  Compression ratio: ${COMPRESSION_RATIO}x"
fi

# Write metrics to temp file, then move atomically
TEMP_FILE="${OUTPUT_FILE}.$$"

cat > "$TEMP_FILE" <<EOF
# HELP borg_backup_last_success_timestamp Unix timestamp of last successful backup verified on remote server
# TYPE borg_backup_last_success_timestamp gauge
borg_backup_last_success_timestamp{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${TIMESTAMP}

# HELP borg_backup_age_seconds Age of the last backup in seconds
# TYPE borg_backup_age_seconds gauge
borg_backup_age_seconds{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${AGE_SECONDS}

# HELP borg_backup_check_success Whether the backup check succeeded (1=success, 0=failure)
# TYPE borg_backup_check_success gauge
borg_backup_check_success{hostname="${HOSTNAME}",repo="${REPO_PATH}"} 1

# HELP borg_backup_total_size_bytes Total uncompressed size of all archives in bytes
# TYPE borg_backup_total_size_bytes gauge
borg_backup_total_size_bytes{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${TOTAL_SIZE}

# HELP borg_backup_total_compressed_size_bytes Total compressed size of all archives in bytes
# TYPE borg_backup_total_compressed_size_bytes gauge
borg_backup_total_compressed_size_bytes{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${TOTAL_CSIZE}

# HELP borg_backup_unique_size_bytes Unique data size (deduplicated) in bytes
# TYPE borg_backup_unique_size_bytes gauge
borg_backup_unique_size_bytes{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${UNIQUE_SIZE}

# HELP borg_backup_unique_compressed_size_bytes Unique compressed data size in bytes
# TYPE borg_backup_unique_compressed_size_bytes gauge
borg_backup_unique_compressed_size_bytes{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${UNIQUE_CSIZE}

# HELP borg_backup_total_chunks Total number of chunks
# TYPE borg_backup_total_chunks gauge
borg_backup_total_chunks{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${TOTAL_CHUNKS}

# HELP borg_backup_compression_ratio Compression ratio (uncompressed/compressed)
# TYPE borg_backup_compression_ratio gauge
borg_backup_compression_ratio{hostname="${HOSTNAME}",repo="${REPO_PATH}"} ${COMPRESSION_RATIO}
EOF

mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "✓ Wrote verified backup metrics to ${OUTPUT_FILE}"
