import csv
import sys
from pathlib import Path
from collections import defaultdict
from statistics import mean, stdev

if len(sys.argv) < 2:
    print(f"Usage: python3 {sys.argv[0]} results.csv [output.txt]")
    sys.exit(1)

input_file = sys.argv[1]

if len(sys.argv) >= 3:
    output_file = sys.argv[2]
else:
    name = Path(input_file).stem.lower()

    if "pagerank" in name:
        output_file = "pagerank_rezultati.txt"
    elif "heapsort" in name:
        output_file = "heapsort_rezultati.txt"
    elif "laplace" in name:
        output_file = "laplace2d_rezultati.txt"
    else:
        output_file = f"{Path(input_file).stem}_rezultati.txt"

groups = defaultdict(list)

with open(input_file, newline="") as f:
    reader = csv.DictReader(f)

    for row in reader:

        # Heapsort / PageRank
        if "size" in row:
            key = f"size={row['size']}"

        # Laplace2D
        elif "nx" in row and "ny" in row:
            key = f"{row['nx']}x{row['ny']}"

        else:
            key = "all"

        groups[key].append(row)

lines = []

lines.append(f"Rezultati: {input_file}")
lines.append("=" * 75)
lines.append("")

for key, rows in groups.items():
    times = [float(r["time_sec"]) for r in rows]
    l1 = [float(r["l1_dcm"]) for r in rows]
    l2 = [float(r["l2_dcm"]) for r in rows]
    dram = [float(r["dram_fills"]) for r in rows]

    avg_time = mean(times)
    avg_l1 = mean(l1)
    avg_l2 = mean(l2)
    avg_dram = mean(dram)

    if len(rows) > 1:
        sd_time = stdev(times)
        sd_l1 = stdev(l1)
        sd_l2 = stdev(l2)
        sd_dram = stdev(dram)
    else:
        sd_time = 0
        sd_l1 = 0
        sd_l2 = 0
        sd_dram = 0

    lines.append(key)
    lines.append(f"Runs              : {len(rows)}")

    lines.append(
        f"Time              : {avg_time:.6f} ± {sd_time:.6f} s"
    )

    lines.append(
        f"L1 DCM            : {avg_l1:.0f} ± {sd_l1:.0f}"
    )

    lines.append(
        f"L2 DCM            : {avg_l2:.0f} ± {sd_l2:.0f}"
    )

    lines.append(
        f"DRAM fills        : {avg_dram:.0f} ± {sd_dram:.0f}"
    )

    lines.append("")

result = "\n".join(lines)

# terminal output
print(result)

# saving to a .txt file
with open(output_file, "w") as f:
    f.write(result)

print(f"\nRezultati shranjeni v: {output_file}")