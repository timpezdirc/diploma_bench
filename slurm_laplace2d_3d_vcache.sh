#!/bin/bash
#SBATCH --job-name=laplace2d_3d_vcache
#SBATCH --partition=amd
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=02:00:00
#SBATCH --output=laplace2d_3d_vcache_%j.out
#SBATCH --error=laplace2d_3d_vcache_%j.err

echo "===== Job info ====="
echo "Job ID     : $SLURM_JOB_ID"
echo "Node       : $SLURM_NODELIST"
echo "CPUs/Task  : $SLURM_CPUS_PER_TASK"
echo "Start time : $(date)"
echo "===================="

# one container execution for everything
srun \
  --container-image=timpezdirc/diploma-bench:latest \
  --container-mounts=$HOME:/workspace \
  --container-workdir=/workspace/diploma \
  bash -c '

set -e

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OMP_PROC_BIND=true
export OMP_PLACES=cores

echo "===== BUILD STEP ====="
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target laplace2d -j1

echo "===== BENCHMARK START ====="

declare -a RESULT_LABELS
declare -a RESULT_AVGS

run_laplace () {
    NX=$1
    NY=$2
    MAXITER=$3
    RUNS=$4
    LABEL=$5

    echo ""
    echo "======================================="
    echo "--- $LABEL ---"
    echo "Grid size    = ${NX}x${NY}"
    echo "Max iters    = $MAXITER"
    echo "Runs         = $RUNS"
    echo "======================================="

    OUTPUT=$(./build/laplace2d $NX $NY $MAXITER $RUNS 2>&1)
    echo "$OUTPUT"

    TIME=$(echo "$OUTPUT" | grep -oP "Average time over [0-9]+ runs: \K[0-9.eE+-]+" | tail -1)

    if [[ -z "$TIME" ]]; then
        echo "WARNING: could not parse timing output for $LABEL"
        TIME="NA"
    fi

    RESULT_LABELS+=("$LABEL")
    RESULT_AVGS+=("$TIME")
}

# Run 1: 1024x1024 ~16 MB total
run_laplace 1024 1024 200 30 "Run 1: 1024x1024 (both caches hold the problem)"

# Run 2: 4096x4096 ~256 MB total
run_laplace 4096 4096 200 20 "Run 2: 4096x4096 (DRAM-bound on both nodes)"

# Run 3: 8192x8192 ~1 GB total
run_laplace 8192 8192 200 10 "Run 3: 8192x8192 (deeply DRAM-bound)"

# Run 4: 16384x16384 ~4 GB total
run_laplace 16384 16384 100 5 "Run 4: 16384x16384 (extreme DRAM-bound)"

echo ""
echo "======================================="
echo "SUMMARY: Average time per grid size"
echo "======================================="
for ((idx=0; idx<${#RESULT_LABELS[@]}; idx++))
do
    printf "%-55s -> Average time = %s seconds\n" "${RESULT_LABELS[idx]}" "${RESULT_AVGS[idx]}"
done

echo "Finished $(date)"
'