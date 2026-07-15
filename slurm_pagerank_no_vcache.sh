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
  --bind $HOME:/workspace \
  ~/diploma.sif \
  bash -c '

set -e

cd /workspace/diploma

echo "===== BUILD ====="
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target pagerank -j1

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
    echo "Iterations        : $ITER"
    echo "Runs              : $RUNS"
    echo "======================================="

    SUM=0

    for ((i=1;i<=RUNS;i++)); do
        echo "Run $i"

        OUTPUT=$(./build/pagerank $SIZE $EDGES_PER_NODE $ITER)

        TIME=$(echo "$OUTPUT" | grep -oP "Total time in seconds: \K[0-9.eE+-]+" | tail -1)

        if [[ -n "$TIME" ]]; then
            SUM=$(awk -v a="$SUM" -v b="$TIME" "BEGIN{printf \"%.10f\", a+b}")
        else
            echo "WARNING: could not parse timing output (SIZE=$SIZE run=$i)"
            echo "$OUTPUT"
        fi
    done

    AVG=$(awk -v s="$SUM" -v n="$RUNS" "BEGIN{printf \"%.6f\", s/n}")

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
    printf "SIZE=%-12s -> AVG = %s seconds\n" "${RESULT_SIZES[i]}" "${RESULT_AVGS[i]}"
done

echo "===== Done: $(date) ====="

'