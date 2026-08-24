#!/bin/bash
#SBATCH --job-name=pagerank_no_vcache
#SBATCH --partition=all
#SBATCH --nodes=1
#SBATCH --nodelist=wn[164-169]
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=64G
#SBATCH --time=03:00:00
#SBATCH --output=pagerank_no_vcache_%j.out
#SBATCH --error=pagerank_no_vcache_%j.err

echo "===== Job info ====="
echo "Job ID     : $SLURM_JOB_ID"
echo "Node       : $SLURM_NODELIST"
echo "Start time : $(date)"
echo "===================="

apptainer exec \
  --containall \
  --bind "$HOME:/workspace" \
  --env SLURM_JOB_ID="$SLURM_JOB_ID" \
  ~/diploma.sif \
  bash -c '

set -e

cd /workspace/diploma

# each SLURM job gets its own build directory
BUILD_DIR="build_pagerank_${SLURM_JOB_ID}"

RESULTS_CSV="pagerank_no_vcache_runs.csv"
echo "size,run,time_sec,l1_dcm,l2_dcm,dram_fills" > "$RESULTS_CSV"

echo "===== BUILD ====="

rm -rf "$BUILD_DIR"

cmake -S . -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_PAPI=ON

cmake --build "$BUILD_DIR" --target pagerank -j1

echo "===== BENCHMARK START ====="

declare -a RESULT_SIZES
declare -a RESULT_AVGS

run_test() {
    SIZE=$1
    EDGES_PER_NODE=16
    ITER=10
    RUNS=20

    echo ""
    echo "======================================="
    echo "Nodes             : $SIZE"
    echo "Edges per node    : $EDGES_PER_NODE"
    echo "Iterations        : $ITER"
    echo "Runs              : $RUNS"
    echo "======================================="

    SUM=0

    for ((i=1; i<=RUNS; i++)); do
        OUTPUT=$(
            ./"$BUILD_DIR"/pagerank \
                "$SIZE" \
                "$EDGES_PER_NODE" \
                "$ITER"
        )

        TIME=$(
            echo "$OUTPUT" |
            grep -oP \
            "Total time in seconds: \K[0-9.eE+-]+" |
            tail -1
        )

        L1=$(
            echo "$OUTPUT" |
            grep -oP \
            "L1 DCM: \K[0-9]+" |
            tail -1
        )

        L2=$(
            echo "$OUTPUT" |
            grep -oP \
            "L2 DCM: \K[0-9]+" |
            tail -1
        )

        DRAM=$(
            echo "$OUTPUT" |
            grep -oP \
            "DRAM FILLS: \K[0-9]+" |
            tail -1
        )

        if [[ -n "$TIME" &&
              -n "$L1" &&
              -n "$L2" &&
              -n "$DRAM" ]]; then

            echo "  Run $i / $RUNS: Time=$TIME s | L1_DCM=$L1 | L2_DCM=$L2 | DRAM_FILLS=$DRAM"

            echo "$SIZE,$i,$TIME,$L1,$L2,$DRAM" \
                >> "$RESULTS_CSV"

            SUM=$(
                awk \
                    -v a="$SUM" \
                    -v b="$TIME" \
                    "BEGIN { printf \"%.10f\", a+b }"
            )

        else

            echo "ERROR: could not parse output (SIZE=$SIZE run=$i)"
            echo "$OUTPUT"
            exit 1

        fi

    done

    AVG=$(
        awk \
            -v s="$SUM" \
            -v n="$RUNS" \
            "BEGIN { printf \"%.6f\", s/n }"
    )

    echo "---- Average time for SIZE=$SIZE: $AVG seconds ----"

    RESULT_SIZES+=("$SIZE")
    RESULT_AVGS+=("$AVG")
}

run_test 1000000
run_test 5000000
run_test 10000000
run_test 30000000

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
echo "Build directory  : $BUILD_DIR"
echo "===== Done: $(date) ====="

'