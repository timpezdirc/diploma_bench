#!/bin/bash
#SBATCH --job-name=laplace2d_3d_vcache
#SBATCH --partition=amd
#SBATCH --nodelist=api
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --hint=nomultithread
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=laplace2d_3d_vcache_%j.out
#SBATCH --error=laplace2d_3d_vcache_%j.err

set -euo pipefail

PROJECT_DIR="$HOME/diploma"
CONTAINER_IMAGE="$HOME/containers/diploma-bench.sqsh"

# temporary perf files
PERF_DIR="${SCRATCH:-/tmp}/laplace_perf_${SLURM_JOB_ID}"

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
echo "CPUs/Task  : $SLURM_CPUS_PER_TASK"
echo "Start time : $(date)"
echo "===================="

# OpenMP settings
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OMP_PROC_BIND=true
export OMP_PLACES=cores

srun \
  --cpu-bind=none \
  --container-image="$CONTAINER_IMAGE" \
  --container-mounts="$HOME:/workspace,$PERF_DIR:/tmp/perf-control,$HOST_PERF:/tmp/host-perf" \
  --container-workdir=/workspace/diploma \
  bash -s <<'EOF'

set -euo pipefail

PROJECT_DIR="/workspace/diploma"

# each SLURM job gets its own build directory
BUILD_DIR="build_laplace2d_${SLURM_JOB_ID}"

# unique result file for this SLURM job
RESULTS_CSV="$PROJECT_DIR/laplace2d_3d_vcache_runs_${SLURM_JOB_ID}.csv"

# temporary perf files
PERF_DIR="/tmp/perf-control"

echo ""
echo "===== BUILD STEP ====="
echo "Build directory: $BUILD_DIR"

cmake -S . -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" \
    --target laplace2d \
    -j1


BIN="./$BUILD_DIR/laplace2d"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: $BIN was not built." >&2
    exit 1
fi

echo "Executable: $BIN"

echo "nx,ny,max_iter,run,time_sec,l1_dcm,l2_dcm,dram_fills" \
    > "$RESULTS_CSV"

echo ""
echo "===== BENCHMARK START ====="

declare -a RESULT_LABELS
declare -a RESULT_AVGS

# run one grid size
run_laplace () {
    local NX=$1
    local NY=$2
    local MAXITER=$3
    local RUNS=$4
    local LABEL=$5

    local SUM=0

    echo ""
    echo "======================================="
    echo "$LABEL"
    echo "Grid size       : ${NX}x${NY}"
    echo "Max iterations  : $MAXITER"
    echo "Runs            : $RUNS"
    echo "Threads         : $OMP_NUM_THREADS"
    echo "======================================="

    for ((i=1; i<=RUNS; i++)); do
        local CTL_FIFO="$PERF_DIR/ctl_${NX}_${NY}_${i}"
        local ACK_FIFO="$PERF_DIR/ack_${NX}_${NY}_${i}"
        local PERF_FILE="$PERF_DIR/perf_${NX}_${NY}_${i}.csv"

        rm -f \
            "$CTL_FIFO" \
            "$ACK_FIFO" \
            "$PERF_FILE"

        mkfifo "$CTL_FIFO"
        mkfifo "$ACK_FIFO"


        # open both FIFOs before starting perf to prevent blocking
        exec 9<>"$CTL_FIFO"
        exec 8<>"$ACK_FIFO"

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
              -- "$BIN" \
                   "$NX" \
                   "$NY" \
                   "$MAXITER" \
                   1
        )

        # close FIFO descriptors
        exec 9>&-
        exec 8>&-

        rm -f \
            "$CTL_FIFO" \
            "$ACK_FIFO"

        local TIME

        TIME=$(
            echo "$OUTPUT" |
            grep -oP \
            "Average time over [0-9]+ runs: \K[0-9.eE+-]+" |
            tail -1
        )

        local L1
        local L2
        local DRAM

        L1=$(
            awk -F';' '
                $3 ~ /L1-dcache-load-misses/ {
                    gsub(/[[:space:]]/, "", $1)
                    print $1
                    exit
                }
            ' "$PERF_FILE"
        )

        L2=$(
            awk -F';' '
                $3 ~ /l2_cache_misses_from_dc_misses/ {
                    gsub(/[[:space:]]/, "", $1)
                    print $1
                    exit
                }
            ' "$PERF_FILE"
        )

        DRAM=$(
            awk -F';' '
                $3 ~ /dram_fills/ {
                    gsub(/[[:space:]]/, "", $1)
                    print $1
                    exit
                }
            ' "$PERF_FILE"
        )

        if [[ -z "$TIME" ||
              -z "$L1" ||
              -z "$L2" ||
              -z "$DRAM" ]]; then

            echo "ERROR: failed to parse results for ${NX}x${NY} run=$i"

            echo ""
            echo "Program output:"
            echo "$OUTPUT"

            echo ""
            echo "Perf output:"
            cat "$PERF_FILE"

            exit 1
        fi

        echo "  Run $i / $RUNS: Time=$TIME s | L1_DCM=$L1 | L2_DCM=$L2 | DRAM_FILLS=$DRAM"
        echo "$NX,$NY,$MAXITER,$i,$TIME,$L1,$L2,$DRAM" \
            >> "$RESULTS_CSV"

        # sum time for final average
        SUM=$(
            awk \
                -v a="$SUM" \
                -v b="$TIME" \
                'BEGIN {
                    printf "%.10f", a+b
                }'
        )

        rm -f "$PERF_FILE"

    done

    local AVG

    AVG=$(
        awk \
            -v s="$SUM" \
            -v n="$RUNS" \
            'BEGIN {
                printf "%.6f", s/n
            }'
    )

    echo ""
    echo "---- AVG for ${NX}x${NY}: $AVG seconds ----"

    RESULT_LABELS+=("$LABEL")
    RESULT_AVGS+=("$AVG")
}

run_laplace \
    1024 1024 200 30 \
    "Run 1: 1024x1024"


run_laplace \
    4096 4096 200 20 \
    "Run 2: 4096x4096"


run_laplace \
    8192 8192 200 10 \
    "Run 3: 8192x8192"


run_laplace \
    16384 16384 100 5 \
    "Run 4: 16384x16384"

echo ""
echo "======================================="
echo "SUMMARY"
echo "======================================="


for ((idx=0; idx<${#RESULT_LABELS[@]}; idx++)); do
    printf "%-30s -> Average time = %s seconds\n" \
        "${RESULT_LABELS[idx]}" \
        "${RESULT_AVGS[idx]}"
done

echo ""
echo "Results saved to : $RESULTS_CSV"
echo "Build directory  : $BUILD_DIR"
echo "Finished         : $(date)"

EOF