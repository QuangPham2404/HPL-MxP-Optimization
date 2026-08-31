#!/bin/bash
# Submit the GAAS multi-node scaling validation sweep.
# Configurations: nodes x GPUs-per-node. Uses select=N:ngpus=G (no mpiprocs),
# which is the proven form on this cluster (mpiprocs>1 breaks pbsdsh -n).

set -euo pipefail

cd "$(dirname "$0")"

# label=NNODES:GPUS
declare -a CONFIGS=(
  "2x1:2:1"
  "2x2:2:2"
  "2x4:2:4"
  "3x1:3:1"
  "3x2:3:2"
  "3x4:3:4"
)

mkdir -p outputs

for cfg in "${CONFIGS[@]}"; do
  label="${cfg%%:*}"
  rest="${cfg#*:}"
  nnodes="${rest%%:*}"
  gpus="${rest##*:}"

  jobid=$(qsub \
    -v "LABEL=$label,GPUS=$gpus" \
    -N "HPL_MXP_SCALE_${label}" \
    -l "select=${nnodes}:ngpus=${gpus}" \
    -o "outputs/scale_${label}.o" \
    -e "outputs/scale_${label}.e" \
    probe_scaling.pbs)
  echo "submitted ${label} (select=${nnodes}:ngpus=${gpus}) -> $jobid"
done

echo "sweep submitted"