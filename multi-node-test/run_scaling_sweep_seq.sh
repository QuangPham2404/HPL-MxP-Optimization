#!/bin/bash
# Submit the scaling sweep SEQUENTIALLY, waiting for each job to finish before
# submitting the next. Isolated jobs are more reliable than 6-at-once
# submission (avoids cross-job resource/startup contention).

set -euo pipefail
cd "$(dirname "$0")"

CONFIGS=( "2x1:2:1" "2x2:2:2" "2x4:2:4" "3x1:3:1" "3x2:3:2" "3x4:3:4" )
mkdir -p outputs

for cfg in "${CONFIGS[@]}"; do
  label="${cfg%%:*}"; rest="${cfg#*:}"
  nnodes="${rest%%:*}"; gpus="${rest##*:}"

  jobid=$(qsub -v "LABEL=$label,GPUS=$gpus" -N "HPL_MXP_SCALE_${label}" \
    -l "select=${nnodes}:ngpus=${gpus}" \
    -o "outputs/scale_${label}.o" -e "outputs/scale_${label}.e" \
    probe_scaling.pbs)
  echo "[$(date -Is)] submitted ${label} -> ${jobid}"

  # Poll until the job finishes (leaves qstat), up to ~5 min.
  waited=0
  while qstat "$jobid" 2>/dev/null | grep -q "$jobid"; do
    [ "$waited" -ge 300 ] && { echo "  WARN: ${label} still running after ${waited}s, moving on"; break; }
    sleep 10
    waited=$((waited+10))
  done
  echo "[$(date -Is)] ${label} done (waited ${waited}s)"
done

echo "sequential sweep complete"