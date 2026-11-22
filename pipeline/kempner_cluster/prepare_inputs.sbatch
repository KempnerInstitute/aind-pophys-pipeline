#!/bin/bash
#SBATCH --job-name=nf-prepare
#SBATCH --account=kempner_dev
#SBATCH --partition=shared
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --tmp=20G
#SBATCH --time=03:00:00
#SBATCH --output=prepare-%j.out
#SBATCH --error=prepare-%j.err

set -euo pipefail

CONFIG_FILE="${SLURM_SUBMIT_DIR:-.}/kempner_run.env"

set -a
source "$CONFIG_FILE"
set +a

umask 0002
MODELS_URL="https://aind-scratch-data.s3.amazonaws.com/aind-pophys-pipeline/data"
SESSION_SOURCE=":s3,provider=AWS,anonymous=true,region=us-west-2:aind-open-data/$SESSION"
SESSION_URL="https://aind-open-data.s3.us-west-2.amazonaws.com/$SESSION"
SESSION_DIR="$SESSIONS_DIR/$SESSION"
UPGRADER_COMMIT=83c0ae9a4588b0f20c24e93a593c611a758009d1
LOCAL_DIR="/scratch/$USER/$SLURM_JOB_ID"
mkdir -p "$LOCAL_DIR"
trap 'rm -rf "$LOCAL_DIR"' EXIT

echo "node=$(hostname) start=$(date --iso-8601=seconds)"

if [[ ! -x "$NEXTFLOW_ENV/bin/nextflow" ]]; then
    echo "--- Creating the Nextflow environment in $NEXTFLOW_ENV"
    module load Miniforge3/26.9.4-fasrc01
    CONDA_PKGS_DIRS="$LOCAL_DIR/pkgs" conda create --yes --prefix "$NEXTFLOW_ENV" \
        --override-channels --channel conda-forge --channel bioconda \
        nextflow=24.10.4 openjdk=17
fi
PATH="$NEXTFLOW_ENV/bin:$PATH" nextflow -version

echo "--- Downloading the model files to $DATA_PATH"
mkdir -p "$DATA_PATH"
(
    cd "$DATA_PATH"
    curl -fsS --retry 5 -o SHA256SUMS "$MODELS_URL/SHA256SUMS"
    if ! sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1; then
        awk '{print $2}' SHA256SUMS | while read -r file; do
            mkdir -p "$(dirname "$file")"
            curl -fsS --retry 5 -o "$file" "$MODELS_URL/$file"
        done
    fi
    sha256sum -c SHA256SUMS
)

echo "--- Downloading $SESSION to $SESSION_DIR"
mkdir -p "$SESSION_DIR"
find "$SESSION_DIR" -name '*.partial' -delete
if [[ -f "$SESSION_DIR/data_description.json.v1" ]]; then
    mv -f "$SESSION_DIR/data_description.json.v1" "$SESSION_DIR/data_description.json"
fi
rclone lsf -R --files-only "$SESSION_SOURCE" \
    | awk -v base="$SESSION_URL" '{printf "%s/%s\n  out=%s\n", base, $0, $0}' > "$LOCAL_DIR/session.aria2"
# Each compute-node connection to S3 gets about 0.3 MiB/s and long ones can drop, so aria2c uses
# 16 connections per file and 8 MiB segments; a dropped segment is fetched again on its own.
aria2c --input-file="$LOCAL_DIR/session.aria2" --dir="$SESSION_DIR" \
    --max-concurrent-downloads=8 --max-connection-per-server=16 --split=16 --min-split-size=8M \
    --continue=true --auto-file-renaming=false --file-allocation=none \
    --max-tries=20 --retry-wait=10 --timeout=60 --connect-timeout=30 \
    --show-console-readout=false --summary-interval=300 --console-log-level=warn --download-result=hide
rclone check "$SESSION_SOURCE" "$SESSION_DIR" --one-way
echo "files=$(find "$SESSION_DIR" -type f | wc -l) bytes=$(find "$SESSION_DIR" -type f -printf '%s\n' | awk '{s+=$1} END {print s}')"

# The metadata aggregator reads data_description.json with the aind-data-schema v2 model only.
version=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("schema_version", ""))' \
    "$SESSION_DIR/data_description.json")
if [[ "$version" == 1.* ]]; then
    echo "--- Upgrading data_description.json from schema $version to v2 (original kept as .v1)"
    tag=$(sed -n 's/.*PIPELINE_VERSION = "\([^"]*\)".*/\1/p' "$PIPELINE_PATH/nextflow.config" | head -n 1)
    git clone --quiet https://github.com/AllenNeuralDynamics/aind-metadata-upgrader "$LOCAL_DIR/upgrader"
    git -C "$LOCAL_DIR/upgrader" -c advice.detachedHead=false checkout --quiet "$UPGRADER_COMMIT"
    singularity exec --no-home --cleanenv -B "$LOCAL_DIR" -B "$SESSION_DIR" -B "$PIPELINE_PATH" \
        "$NXF_SINGULARITY_LIBRARYDIR/ghcr.io-allenneuraldynamics-pophys-aggregator-$tag.img" \
        python "$PIPELINE_PATH/upgrade_data_description.py" "$LOCAL_DIR/upgrader/src" \
        "$SESSION_DIR/data_description.json" "$LOCAL_DIR/data_description.json"
    mv "$SESSION_DIR/data_description.json" "$SESSION_DIR/data_description.json.v1"
    cp "$LOCAL_DIR/data_description.json" "$SESSION_DIR/data_description.json"
fi

echo "end=$(date --iso-8601=seconds)"
