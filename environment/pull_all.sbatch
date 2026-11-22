#!/bin/bash
#SBATCH --account=kempner_dev
#SBATCH --partition=shared
#SBATCH --job-name=omnipilot-201
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --tmp=40G
#SBATCH --time=04:00:00
#SBATCH --chdir=/n/netscratch/kempner_grads/Lab/bdesinghu/jobs
#SBATCH --output=/n/netscratch/kempner_grads/Lab/bdesinghu/jobs/output/omnipilot-%j.out
#SBATCH --error=/n/netscratch/kempner_grads/Lab/bdesinghu/jobs/output/omnipilot-%j.err

set -euo pipefail

CONFIG_FILE="/n/netscratch/kempner_grads/Lab/bdesinghu/jobs/config/omnipilot-201.env"

set -a
source "$CONFIG_FILE"
set +a

LOCAL_DIR="/scratch/$USER/$SLURM_JOB_ID"
trap 'rm -rf "$LOCAL_DIR"' EXIT

# On netscratch (NFS), unpacking took about 16 min per image and the temporary folder could not be removed.
export SINGULARITY_CACHEDIR="$LOCAL_DIR/cache"
export SINGULARITY_TMPDIR="$LOCAL_DIR/tmp"
export APPTAINER_CACHEDIR="$SINGULARITY_CACHEDIR"
export APPTAINER_TMPDIR="$SINGULARITY_TMPDIR"
# Layer cache lets the ten images built from Dockerfile_python share downloaded base layers.
unset SINGULARITY_DISABLE_CACHE APPTAINER_DISABLE_CACHE

# Singularity reuses a layer that already exists in this OCI layout and skips its download.
BLOB_DIR="$SINGULARITY_CACHEDIR/cache/blob/blobs/sha256"
DOWNLOAD_DIR="$LOCAL_DIR/download"
mkdir -p "$BLOB_DIR" "$DOWNLOAD_DIR" "$SINGULARITY_TMPDIR"

ghcr_token() {
    curl -fsS "https://ghcr.io/token?scope=repository:$1:pull" | jq -r .token
}

# Compute-node connections get about 1.75 MB/s each and drop after about 9 min, and singularity
# cannot resume a layer; aria2c uses 8 connections and resumes each layer from where it stopped.
fetch_blob() {
    local repo="$1" digest="$2" hex="${2#sha256:}" attempt url
    for (( attempt = 1; attempt <= BLOB_ATTEMPTS; attempt++ )); do
        url=$(curl -fsS -o /dev/null -w '%{redirect_url}' \
            -H "Authorization: Bearer $(ghcr_token "$repo")" \
            "https://ghcr.io/v2/$repo/blobs/$digest") || url=""
        if [[ -n "$url" ]] && aria2c --continue=true --auto-file-renaming=false --file-allocation=none \
                --max-connection-per-server=8 --split=8 --min-split-size=32M \
                --max-tries=5 --retry-wait=10 --timeout=60 --connect-timeout=30 \
                --show-console-readout=false --summary-interval=120 --console-log-level=warn \
                --download-result=hide --dir="$DOWNLOAD_DIR" --out="$hex" "$url"; then
            if sha256sum --check --status <<< "$hex  $DOWNLOAD_DIR/$hex"; then
                mv "$DOWNLOAD_DIR/$hex" "$BLOB_DIR/$hex"
                return 0
            fi
            echo "Checksum mismatch for $digest; downloading it again"
            rm -f "$DOWNLOAD_DIR/$hex" "$DOWNLOAD_DIR/$hex.aria2"
        fi
        echo "Download of $digest incomplete (attempt $attempt of $BLOB_ATTEMPTS)"
        sleep 10
    done
    return 1
}

echo "node=$(hostname) start=$(date --iso-8601=seconds)"

if [[ "$IMAGES" == all ]]; then
    IMAGES=$(jq -r 'keys_unsorted | join(",")' "$REPO_DIR/pipeline/images.json")
fi

for image in ${IMAGES//,/ }; do
    name=$(jq -r --arg i "$image" '.[$i].image_name' "$REPO_DIR/pipeline/images.json")
    repo="$REGISTRY_ORG/$name"
    if [[ -f "$IMAGE_DIR/ghcr.io-$REGISTRY_ORG-$name-$CONTAINER_TAG.img" && "${FORCE:-false}" != true ]]; then
        continue
    fi
    manifest=$(curl -fsS -H "Authorization: Bearer $(ghcr_token "$repo")" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
        "https://ghcr.io/v2/$repo/manifests/$CONTAINER_TAG")
    if ! jq -e '.layers' <<< "$manifest" >/dev/null; then
        echo "Error: $repo:$CONTAINER_TAG is not a single-platform image manifest"
        exit 1
    fi
    for digest in $(jq -r '.layers[].digest' <<< "$manifest"); do
        if [[ -f "$BLOB_DIR/${digest#sha256:}" ]]; then
            continue
        fi
        start=$SECONDS
        fetch_blob "$repo" "$digest"
        echo "Fetched $image layer ${digest:7:12} ($(stat -c %s "$BLOB_DIR/${digest#sha256:}") bytes) in $((SECONDS - start)) s"
    done
done

"$REPO_DIR/environment/pull_all.sh" "$CONTAINER_TAG" "$IMAGES"
echo "end=$(date --iso-8601=seconds)"
