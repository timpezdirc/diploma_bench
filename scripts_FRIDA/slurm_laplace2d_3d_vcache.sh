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

if [[ ! -f "$CONTAINER_IMAGE" ]]; then
    echo "ERROR: container image not found: $CONTAINER_IMAGE" >&2
    exit 1
fi

srun \
  --cpu-bind=none \
  --container-image="$CONTAINER_IMAGE" \
  --container-mounts="$HOME:/workspace" \
  --container-workdir=/workspace/diploma \
  bash -s <<'EOF'

set -euo pipefail

PROJECT_DIR="/workspace/diploma"

# each SLURM job gets its own build directory
BUILD_DIR="build_laplace2d_${SLURM_JOB_ID}"

# unique result file for this SLURM job
RESULTS_CSV="$PROJECT_DIR/laplace2d_3d_vcache_runs_${SLURM_JOB_ID}.csv"

echo ""
echo "===== BUILD STEP ====="
echo "Build directory: $BUILD_DIR"

cmake -S . -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_PAPI=ON

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

        local OUTPUT

        OUTPUT=$(
            "$BIN" \
                "$NX" \
                "$NY" \
                "$MAXITER" \
                1
        )

        local TIME
        local L1
        local L2
        local DRAM

        TIME=$(
            echo "$OUTPUT" |
            grep -oP \
            "Average time over [0-9]+ runs: \K[0-9.eE+-]+" |
            tail -1
        )

        L1=$(
            echo "$OUTPUT" |
            grep -oP \
            "Average L1 DCM: \K[0-9]+" |
            tail -1
        )

        L2=$(
            echo "$OUTPUT" |
            grep -oP \
            "Average L2 DCM: \K[0-9]+" |
            tail -1
        )

        DRAM=$(
            echo "$OUTPUT" |
            grep -oP \
            "Average DRAM FILLS: \K[0-9]+" |
            tail -1
        )

        if [[ -z "$TIME" ||
              -z "$L1" ||
              -z "$L2" ||
              -z "$DRAM" ]]; then

            echo "ERROR: failed to parse results for ${NX}x${NY} run=$i"

            echo ""
            echo "Program output:"
            echo "$OUTPUT"

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