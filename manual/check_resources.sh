#!/bin/bash
echo "============================================"
echo "        HPC Node Resource Summary"
echo "============================================"
echo ""
printf "%-16s %s\n" "Hostname:" "$(hostname)"
printf "%-16s %s\n" "User:" "$(whoami)"
printf "%-16s %s\n" "SLURM Job ID:" "${SLURM_JOB_ID:-N/A}"
printf "%-16s %s\n" "Partition:" "${SLURM_JOB_PARTITION:-N/A}"
echo ""
echo "-------- CPU --------"
printf "%-16s %s\n" "Allocated CPUs:" "${SLURM_CPUS_ON_NODE:-$(nproc)}"
printf "%-16s %s\n" "CPU Model:" "$(lscpu 2>/dev/null | grep 'Model name' | sed 's/Model name:\s*//')"
echo ""
echo "-------- Memory --------"
TOTAL_MEM=$(free -h | awk '/Mem:/ {print $2}')
AVAIL_MEM=$(free -h | awk '/Mem:/ {print $7}')
SLURM_MEM="${SLURM_MEM_PER_NODE:+${SLURM_MEM_PER_NODE}MB}"
printf "%-16s %s\n" "Node Total:" "$TOTAL_MEM"
printf "%-16s %s\n" "Available:" "$AVAIL_MEM"
printf "%-16s %s\n" "SLURM Alloc:" "${SLURM_MEM:-N/A}"
echo ""
echo "-------- GPU --------"
if command -v nvidia-smi &>/dev/null; then
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
    printf "%-16s %s\n" "GPU Count:" "$GPU_COUNT"
    nvidia-smi -L 2>/dev/null | while read -r line; do
        echo "  $line"
    done
    echo ""
    nvidia-smi --query-gpu=name,memory.total,memory.free,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | while IFS=, read -r name mem_total mem_free util; do
        printf "  %-20s | Mem: %6s MB free / %6s MB | Util: %s%%\n" \
            "$(echo "$name" | xargs)" "$(echo "$mem_free" | xargs)" "$(echo "$mem_total" | xargs)" "$(echo "$util" | xargs)"
    done
else
    echo "  No GPU available (or nvidia-smi not found)"
fi
echo ""
echo "-------- Storage --------"
df -h /cluster/home 2>/dev/null | awk 'NR==2 {printf "%-16s %s used / %s total (%s)\n", "Home:", $3, $2, $5}'
echo ""
echo "============================================"
