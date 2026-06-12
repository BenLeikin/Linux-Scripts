#!/usr/bin/env bash
#
# slurm_alloc_test.sh
# Usage:
#   ./slurm_alloc_test.sh              # test all allocatable nodes in all partitions
#   ./slurm_alloc_test.sh <partition>  # test nodes in a specific partition

PARTITION="$1"
STATES="idle,mix,alloc"
TIMEOUT=20     # seconds to wait per node before calling it a TIMEOUT

if [ -n "$PARTITION" ]; then
    echo "Testing nodes Slurm considers allocatable in partition: $PARTITION"
    NODE_LIST=$(sinfo -h -N -p "$PARTITION" -t "$STATES" -o '%N')
else
    echo "Testing nodes Slurm considers allocatable in all partitions"
    NODE_LIST=$(sinfo -h -N -t "$STATES" -o '%N')
fi

if [ -z "$NODE_LIST" ]; then
    echo "No allocatable nodes found with states $STATES."
    echo "Check 'sinfo' output and partition names."
    exit 1
fi

SRUN_PART=""
if [ -n "$PARTITION" ]; then
    SRUN_PART="-p $PARTITION"
fi

for node in $NODE_LIST; do
    printf "%-20s : " "$node"

    # Run a small test step on that node, but give up after $TIMEOUT seconds
    OUTPUT=$(timeout ${TIMEOUT}s srun $SRUN_PART -N1 -n1 -w "$node" \
                     --time=00:01:00 /bin/hostname 2>&1)
    RC=$?

    # Check if slurmstepd complained even if RC is 0
    echo "$OUTPUT" | grep -q 'slurmstepd:' && HAS_STEPD_ERR=1 || HAS_STEPD_ERR=0

    if [ $RC -eq 124 ]; then
        echo "TIMEOUT (no response in ${TIMEOUT}s)"
    elif [ $RC -ne 0 ]; then
        echo "FAILED (rc=$RC)"
    elif [ $HAS_STEPD_ERR -eq 1 ]; then
        echo "OK_WITH_ERRORS"
    else
        echo "OK"
    fi

    # If there was any output, show it indented for context
    if [ -n "$OUTPUT" ]; then
        echo "$OUTPUT" | sed 's/^/    /'
    fi
done
