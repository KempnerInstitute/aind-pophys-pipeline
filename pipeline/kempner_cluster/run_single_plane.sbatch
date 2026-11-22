#!/bin/bash
#SBATCH --job-name=nf-head
#SBATCH --account=kempner_dev
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=3-00:00:00
#SBATCH --output=head-%j.out
#SBATCH --error=head-%j.err

set -euo pipefail

CONFIG_FILE="${SLURM_SUBMIT_DIR:-.}/kempner_run.env"

set -a
source "$CONFIG_FILE"
set +a

export PATH="$NEXTFLOW_ENV/bin:$PATH"
export NEXTFLOW_BIN="$NEXTFLOW_ENV/bin/nextflow"
if [[ -d "$NEXTFLOW_ENV/lib/jvm" ]]; then
    export JAVA_HOME="$NEXTFLOW_ENV/lib/jvm"
else
    unset JAVA_HOME
fi
export HDF5_USE_FILE_LOCKING=FALSE

LOCAL_DIR="/scratch/$USER/$SLURM_JOB_ID"
export SINGULARITY_TMPDIR="$LOCAL_DIR/tmp"
export APPTAINER_TMPDIR="$SINGULARITY_TMPDIR"
mkdir -p "$SINGULARITY_TMPDIR"
trap 'rm -rf "$LOCAL_DIR"' EXIT

echo "node=$(hostname) start=$(date --iso-8601=seconds)"
# -resume reuses finished tasks from the same launch directory and WORKDIR; a first run starts fresh.
bash "$PIPELINE_PATH/slurm_submit.sh" \
    --ophys_mount_url "$SESSIONS_DIR/$SESSION" \
    --acquisition_data_type "$ACQUISITION_DATA_TYPE" \
    -resume

# Each step also outputs its whole plane folder, so publishDir drops the nested step files as
# duplicates (Nextflow dedupPaths) and each step's plane folder replaces the previous one. Merge
# every finished task's results tree; the aggregator publishes the run-level JSON files itself.
echo "--- Merging step results into $RESULTS_PATH"
"$NEXTFLOW_BIN" log last -f status,process,workdir | while IFS=$'\t' read -r status process workdir; do
    if [[ "$status" == COMPLETED || "$status" == CACHED ]] && [[ -d "$workdir/capsule/results" ]]; then
        echo "$process: $workdir"
        rsync -a --exclude=/processing.json --exclude=/quality_control.json \
            "$workdir/capsule/results/" "$RESULTS_PATH/"
    fi
done
# The docs and nwb/processing.json place the NWB file in nwb/; the NWB step writes it at the results
# root, where the run-level processing.json points, so a relative link stays at the root.
if [[ -d "$RESULTS_PATH/pophys.nwb.zarr" && ! -L "$RESULTS_PATH/pophys.nwb.zarr" ]]; then
    mkdir -p "$RESULTS_PATH/nwb"
    rm -rf "$RESULTS_PATH/nwb/pophys.nwb.zarr"
    mv "$RESULTS_PATH/pophys.nwb.zarr" "$RESULTS_PATH/nwb/pophys.nwb.zarr"
    ln -s nwb/pophys.nwb.zarr "$RESULTS_PATH/pophys.nwb.zarr"
fi
echo "end=$(date --iso-8601=seconds)"
