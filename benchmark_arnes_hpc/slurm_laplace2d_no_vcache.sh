#!/bin/bash
#SBATCH --job-name=laplace2d_no_vcache
#SBATCH --partition=all
#SBATCH --nodes=1
#SBATCH --nodelist=wn[164-169]
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --hint=nomultithread
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=laplace2d_no_vcache_%j.out
#SBATCH --error=laplace2d_no_vcache_%j.err

set -euo pipefail

echo "===== Job info ====="
echo "Job ID     : $SLURM_JOB_ID"
echo "Node       : $SLURM_NODELIST"
echo "CPUs       : $SLURM_CPUS_PER_TASK"
echo "Start time : $(date)"
echo "===================="

apptainer exec \
  --containall \
  --bind "$HOME:/workspace" \
  --env SLURM_JOB_ID="$SLURM_JOB_ID" \
  --env SLURM_CPUS_PER_TASK="$SLURM_CPUS_PER_TASK" \
  --env OMP_NUM_THREADS="$SLURM_CPUS_PER_TASK" \
  --env OMP_PROC_BIND=true \
  --env OMP_PLACES=cores \
  ~/diploma.sif \
  bash -c '

set -euo pipefail

cd /workspace/diploma

BUILD_DIR="build_laplace2d_${SLURM_JOB_ID}"

RESULTS_CSV="laplace2d_no_vcache_runs_${SLURM_JOB_ID}.csv"

echo "nx,ny,max_iter,run,time_sec,l1_dcm,l2_dcm,dram_near,dram_far,dram_fills" \
    > "$RESULTS_CSV"

echo ""
echo "===== BUILD STEP ====="
echo "Build directory: $BUILD_DIR"

rm -rf "$BUILD_DIR"

cmake -S . -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_PAPI=ON

cmake --build "$BUILD_DIR" \
    --target laplace2d \
    -j1

BIN="./$BUILD_DIR/laplace2d"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: executable not found: $BIN"
    exit 1
fi

echo "Executable: $BIN"

echo ""
echo "===== BENCHMARK START ====="

declare -a RESULT_LABELS
declare -a RESULT_AVGS

run_laplace () {
    NX=$1
    NY=$2
    MAXITER=$3
    RUNS=$4
    LABEL=$5

    SUM=0

    echo ""
    echo "======================================="
    echo "$LABEL"
    echo "Grid size       : ${NX}x${NY}"
    echo "Max iterations  : $MAXITER"
    echo "Runs            : $RUNS"
    echo "Threads         : $OMP_NUM_THREADS"
    echo "======================================="

    for ((i=1; i<=RUNS; i++)); do
        OUTPUT=$(
            "$BIN" \
                "$NX" \
                "$NY" \
                "$MAXITER" \
                1
        )

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

        DRAM_NEAR=$(
            echo "$OUTPUT" |
            grep -oP \
                "Average DRAM NEAR: \K[0-9]+" |
            tail -1
        )

        DRAM_FAR=$(
            echo "$OUTPUT" |
            grep -oP \
                "Average DRAM FAR: \K[0-9]+" |
            tail -1
        )

        DRAM=$(
            echo "$OUTPUT" |
            grep -oP \
                "Average DRAM FILLS: \K[0-9]+" |
            tail -1
        )

        if [[ -n "$TIME" &&
              -n "$L1" &&
              -n "$L2" &&
              -n "$DRAM_NEAR" &&
              -n "$DRAM_FAR" &&
              -n "$DRAM" ]]; then

            echo "Run $i / $RUNS: Time=$TIME s | L1_DCM=$L1 | L2_DCM=$L2 | DRAM_NEAR=$DRAM_NEAR | DRAM_FAR=$DRAM_FAR | DRAM_FILLS=$DRAM"

            echo "$NX,$NY,$MAXITER,$i,$TIME,$L1,$L2,$DRAM_NEAR,$DRAM_FAR,$DRAM" \
                >> "$RESULTS_CSV"

            SUM=$(
                awk \
                    -v a="$SUM" \
                    -v b="$TIME" \
                    "BEGIN { printf \"%.10f\", a+b }"
            )

        else

            echo ""
            echo "ERROR: could not parse ${NX}x${NY}, run=$i"
            echo ""
            echo "Raw program output:"
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

    echo ""
    echo "---- AVG for ${NX}x${NY}: $AVG seconds ----"

    RESULT_LABELS+=("$LABEL")
    RESULT_AVGS+=("$AVG")
}

run_laplace 1024 1024 200 30 "1024x1024"
run_laplace 4096 4096 200 20 "4096x4096"
run_laplace 8192 8192 200 10 "8192x8192"
run_laplace 16384 16384 100 5 "16384x16384"

echo ""
echo "======================================="
echo "SUMMARY"
echo "======================================="

for ((idx=0; idx<${#RESULT_LABELS[@]}; idx++)); do
    printf "%-20s -> AVG = %s seconds\n" \
        "${RESULT_LABELS[idx]}" \
        "${RESULT_AVGS[idx]}"
done

echo ""
echo "Results saved to : $RESULTS_CSV"
echo "Build directory  : $BUILD_DIR"
echo "===== Done: $(date) ====="

'