#!/bin/bash
# Submit the HPL-MxP multinode baseline run SEQUENTIALLY, one config at a time,
# waiting for each job to finish before submitting the next. Sequential
# submission avoids the cross-job resource/startup races noted in
# GAAS_MULTINODE_SETUP.md.
#
# Configurations: "label:nnodes:gpus" -> select=nnodes:ngpus=gpus (place=scatter).
# Fixed baseline params (N=120000, NB=1024, row order, square-ish grid) are
# applied inside run_hplmxp_multinode_baseline.pbs.

set -euo pipefail
cd "$(dirname "$0")"

CONFIGS=(
  "2x1:2:1"
  "2x2:2:2"
  "2x4:2:4"
  "2x8:2:8"
  "3x1:3:1"
  "3x2:3:2"
  "3x4:3:4"
  "3x8:3:8"
)
mkdir -p outputs

for cfg in "${CONFIGS[@]}"; do
  label="${cfg%%:*}"; rest="${cfg#*:}"
  nnodes="${rest%%:*}"; gpus="${rest##*:}"

  jobid=$(qsub -v "LABEL=$label,GPUS=$gpus" -N "HPL_MXP_MN_${label}" \
    -l "select=${nnodes}:ngpus=${gpus}" \
    -o "outputs/hplmxp_mn_${label}.o" -e "outputs/hplmxp_mn_${label}.e" \
    run_hplmxp_multinode_baseline.pbs)
  echo "[$(date -Is)] submitted ${label} -> ${jobid}"

  # Poll until the job leaves qstat, up to ~30 min (covers queue + run time).
  waited=0
  while qstat "$jobid" 2>/dev/null | grep -q "$jobid"; do
    if [ "$waited" -ge 1800 ]; then
      echo "  WARN: ${label} still running after ${waited}s, moving on"
      break
    fi
    sleep 15
    waited=$((waited + 15))
  done
  echo "[$(date -Is)] ${label} done (waited ${waited}s)"
done

echo "HPL-MxP multinode baseline sweep complete"