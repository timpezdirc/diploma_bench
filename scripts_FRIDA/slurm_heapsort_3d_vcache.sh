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


if [[ ! -f "$CONTAINER_IMAGE" ]]; then
    echo "ERROR: container image not found: $CONTAINER_IMAGE" >&2
    exit 1
fi


echo "===== Job info ====="
echo "Job ID     : $SLURM_JOB_ID"
echo "Node       : $SLURM_NODELIST"
echo "Start time : $(date)"
echo "===================="


srun \
  --cpu-bind=cores \
  --container-image="$CONTAINER_IMAGE" \
  --container-mounts="$HOME:/workspace" \
  --container-workdir=/workspace/diploma \
  bash -s <<'EOF'

set -euo pipefail

PROJECT_DIR="/workspace/diploma"

# each SLURM job gets its own build directory
BUILD_DIR="build_heapsort_${SLURM_JOB_ID}"

RESULTS_CSV="$PROJECT_DIR/heapsort_3d_vcache_runs_${SLURM_JOB_ID}.csv"


echo ""
echo "===== BUILD STEP ====="
echo "Build directory: $BUILD_DIR"

cmake -S . -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_PAPI=ON

cmake --build "$BUILD_DIR" \
    --target heapsort \
    -j1


BIN="./$BUILD_DIR/heapsort"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: $BIN was not built." >&2
    exit 1
fi


echo "Executable: $BIN"

echo "size,run,time_sec,l1_dcm,l2_dcm,dram_fills" \
    > "$RESULTS_CSV"


echo ""
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
    echo "Array size         : $SIZE"
    echo "Internal runs      : $ITER"
    echo "Benchmark runs     : $RUNS"
    echo "======================================="


    for ((i=1; i<=RUNS; i++)); do

        local OUTPUT

        OUTPUT=$(
            "$BIN" \
                "$SIZE" \
                "$ITER"
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

            echo "ERROR: failed to parse results for SIZE=$SIZE run=$i"

            echo ""
            echo "Program output:"
            echo "$OUTPUT"

            exit 1
        fi


        echo "  Run $i / $RUNS: Time=$TIME s | L1_DCM=$L1 | L2_DCM=$L2 | DRAM_FILLS=$DRAM"

        echo "$SIZE,$i,$TIME,$L1,$L2,$DRAM" \
            >> "$RESULTS_CSV"


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
    echo "---- Average time for SIZE=$SIZE: $AVG seconds ----"


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


echo ""
echo "Results saved to: $RESULTS_CSV"
echo "Build directory : $BUILD_DIR"
echo "Finished        : $(date)"

EOF