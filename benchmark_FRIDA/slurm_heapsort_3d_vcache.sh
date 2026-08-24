#!/bin/bash
#SBATCH --job-name=heapsort_3d_vcache
#SBATCH --partition=amd
#SBATCH --nodelist=api
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=03:00:00
#SBATCH --output=heapsort_3d_vcache_%j.out
#SBATCH --error=heapsort_3d_vcache_%j.err

set -euo pipefail

PROJECT_DIR="$HOME/diploma"
CONTAINER_IMAGE="$HOME/containers/diploma-bench.sqsh"
PERF_DIR="${SCRATCH:-/tmp}/heapsort_perf_${SLURM_JOB_ID}"

KERNEL_RELEASE="$(uname -r)"
HOST_PERF=""

if [[ "$(od -An -N4 -tx1 /usr/bin/perf 2>/dev/null | tr -d ' \n')" == "7f454c46" ]]; then
    HOST_PERF="/usr/bin/perf"
else
    HOST_PERF=$(
        find /usr/lib \
            -maxdepth 4 \
            -type f \
            -name perf \
            -perm -111 \
            2>/dev/null |
        grep -F "$KERNEL_RELEASE" |
        head -1 || true
    )

    if [[ -z "$HOST_PERF" ]]; then
        HOST_PERF=$(
            find /usr/lib \
                -maxdepth 4 \
                -type f \
                -name perf \
                -perm -111 \
                -print -quit \
                2>/dev/null || true
        )
    fi
fi

if [[ -z "$HOST_PERF" || ! -x "$HOST_PERF" ]]; then
    echo "ERROR: could not find host perf binary." >&2
    exit 1
fi

if [[ ! -f "$CONTAINER_IMAGE" ]]; then
    echo "ERROR: container image not found: $CONTAINER_IMAGE" >&2
    exit 1
fi

mkdir -p "$PERF_DIR"
trap 'rm -rf "$PERF_DIR"' EXIT

echo "===== Job info ====="
echo "Job ID     : $SLURM_JOB_ID"
echo "Node       : $SLURM_NODELIST"
echo "Start time : $(date)"
echo "===================="

srun \
  --cpu-bind=none \
  --container-image="$CONTAINER_IMAGE" \
  --container-mounts="$HOME:/workspace,$PERF_DIR:/tmp/perf-control,$HOST_PERF:/tmp/host-perf" \
  --container-workdir=/workspace/diploma \
  bash -s <<'EOF'

set -euo pipefail

PROJECT_DIR="/workspace/diploma"
BUILD_DIR="build_heapsort_${SLURM_JOB_ID}"
RESULTS_CSV="$PROJECT_DIR/heapsort_3d_vcache_runs.csv"
PERF_DIR="/tmp/perf-control"

echo "===== BUILD STEP ====="
echo "Build directory: $BUILD_DIR"

cmake -S . -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --target heapsort -j1


BIN="./$BUILD_DIR/heapsort"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: $BIN was not built." >&2
    exit 1
fi


echo "size,run,time_sec,l1_dcm,l2_dcm,dram_fills,l1_run_pct,l2_run_pct,dram_run_pct" \
    > "$RESULTS_CSV"

echo "===== BENCHMARK START ====="

declare -a RESULT_SIZES
declare -a RESULT_AVGS

run_test () {
    local SIZE=$1
    local ITER=10
    local RUNS=20
    local SUM=0

    echo ""
    echo "======================================="
    echo "Dataset size      : $SIZE"
    echo "Iterations        : $ITER"
    echo "Runs              : $RUNS"
    echo "======================================="

    for ((i=1; i<=RUNS; i++)); do
        local CTL_FIFO="$PERF_DIR/ctl_${SIZE}_${i}"
        local ACK_FIFO="$PERF_DIR/ack_${SIZE}_${i}"
        local PERF_FILE="$PERF_DIR/perf_${SIZE}_${i}.csv"

        rm -f "$CTL_FIFO" "$ACK_FIFO" "$PERF_FILE"

        mkfifo "$CTL_FIFO" "$ACK_FIFO"

        # prevent FIFO open() from blocking
        exec 9<>"$CTL_FIFO"
        exec 8<>"$ACK_FIFO"


        # ----------------------------------------------------
        # Run benchmark under perf
        #
        # Counters initially disabled (--delay=-1).
        # heapsort.cpp enables/disables them around heapSort().
        #
        # 0x48 = 0x08 | 0x40
        # local DRAM + remote DRAM demand fills
        # ----------------------------------------------------

        local OUTPUT

        OUTPUT=$(
            PERF_CTL_FIFO="$CTL_FIFO" \
            PERF_ACK_FIFO="$ACK_FIFO" \
            /tmp/host-perf stat \
              --delay=-1 \
              --control="fifo:${CTL_FIFO},${ACK_FIFO}" \
              --no-big-num \
              -x ';' \
              -o "$PERF_FILE" \
              -e 'L1-dcache-load-misses:u' \
              -e 'l2_cache_misses_from_dc_misses:u' \
              -e 'cpu/event=0x43,umask=0x48,name=dram_fills/u' \
              -- "$BIN" "$SIZE" "$ITER"
        )

        exec 9>&-
        exec 8>&-

        rm -f "$CTL_FIFO" "$ACK_FIFO"

        local TIME

        TIME=$(
            echo "$OUTPUT" |
            grep -oP "Average time over [0-9]+ runs: \K[0-9.eE+-]+" |
            tail -1
        )

        local L1_TOTAL
        local L2_TOTAL
        local DRAM_TOTAL

        local L1_PCT
        local L2_PCT
        local DRAM_PCT

        L1_TOTAL=$(
            awk -F';' '
                $3 ~ /L1-dcache-load-misses/ {
                    gsub(/[[:space:]]/, "", $1)
                    print $1
                    exit
                }
            ' "$PERF_FILE"
        )

        L2_TOTAL=$(
            awk -F';' '
                $3 ~ /l2_cache_misses_from_dc_misses/ {
                    gsub(/[[:space:]]/, "", $1)
                    print $1
                    exit
                }
            ' "$PERF_FILE"
        )

        DRAM_TOTAL=$(
            awk -F';' '
                $3 ~ /dram_fills/ {
                    gsub(/[[:space:]]/, "", $1)
                    print $1
                    exit
                }
            ' "$PERF_FILE"
        )

        # how much of the measurement period each counter
        # actually ran. Ideally these should be ~100%
        L1_PCT=$(
            awk -F';' '
                $3 ~ /L1-dcache-load-misses/ {
                    gsub(/[[:space:]%]/, "", $5)
                    print $5
                    exit
                }
            ' "$PERF_FILE"
        )

        L2_PCT=$(
            awk -F';' '
                $3 ~ /l2_cache_misses_from_dc_misses/ {
                    gsub(/[[:space:]%]/, "", $5)
                    print $5
                    exit
                }
            ' "$PERF_FILE"
        )

        DRAM_PCT=$(
            awk -F';' '
                $3 ~ /dram_fills/ {
                    gsub(/[[:space:]%]/, "", $5)
                    print $5
                    exit
                }
            ' "$PERF_FILE"
        )

        if [[ -z "$TIME" ||
              -z "$L1_TOTAL" ||
              -z "$L2_TOTAL" ||
              -z "$DRAM_TOTAL" ]]; then

            echo "ERROR: failed to parse results for SIZE=$SIZE run=$i"
            echo "----- program output -----"
            echo "$OUTPUT"
            echo "----- perf output -----"
            cat "$PERF_FILE"

            exit 1
        fi

        # perf accumulated counters over ITER heapsorts,
        # convert to average misses per heapsort
        local L1_AVG
        local L2_AVG
        local DRAM_AVG

        L1_AVG=$(
            awk -v x="$L1_TOTAL" -v n="$ITER" \
                'BEGIN { printf "%.0f", x/n }'
        )

        L2_AVG=$(
            awk -v x="$L2_TOTAL" -v n="$ITER" \
                'BEGIN { printf "%.0f", x/n }'
        )

        DRAM_AVG=$(
            awk -v x="$DRAM_TOTAL" -v n="$ITER" \
                'BEGIN { printf "%.0f", x/n }'
        )

        echo "  Run $i / $RUNS: Time=$TIME s | L1_DCM=$L1_AVG | L2_DCM=$L2_AVG | DRAM_FILLS=$DRAM_AVG"
        echo "$SIZE,$i,$TIME,$L1_AVG,$L2_AVG,$DRAM_AVG,$L1_PCT,$L2_PCT,$DRAM_PCT" \
            >> "$RESULTS_CSV"

        SUM=$(
            awk -v a="$SUM" -v b="$TIME" \
                'BEGIN { printf "%.10f", a+b }'
        )

        rm -f "$PERF_FILE"

    done

    local AVG

    AVG=$(
        awk -v s="$SUM" -v n="$RUNS" \
            'BEGIN { printf "%.6f", s/n }'
    )

    echo "---- AVG for SIZE=$SIZE: $AVG seconds ----"

    RESULT_SIZES+=("$SIZE")
    RESULT_AVGS+=("$AVG")
}

run_test 5000000
run_test 10000000
run_test 20000000
run_test 80000000

echo ""
echo "======================================="
echo "SUMMARY"
echo "======================================="

for ((i=0; i<${#RESULT_SIZES[@]}; i++)); do
    printf "SIZE=%-12s -> AVG = %s seconds\n" \
        "${RESULT_SIZES[i]}" \
        "${RESULT_AVGS[i]}"
done


echo "Results saved to: $RESULTS_CSV"
echo "Build directory : $BUILD_DIR"
echo "Finished $(date)"

EOF