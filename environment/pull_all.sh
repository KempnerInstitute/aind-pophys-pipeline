#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PIPELINE_DIR="$ENV_DIR/../pipeline"
IMAGES_JSON="$PIPELINE_DIR/images.json"
ALL_IMAGES=$(jq -r 'keys_unsorted | join(",")' "$IMAGES_JSON")
REGISTRY="${IMAGE_REGISTRY:-ghcr.io/allenneuraldynamics}"
IMAGE_DIR="${IMAGE_DIR:-/n/holylfs06/LABS/kempner_shared/Everyone/workflow/ophys-roi-extraction-2026/images}"
RELEASE_TAG=$(sed -n 's/.*PIPELINE_VERSION = "\([^"]*\)".*/\1/p' "$PIPELINE_DIR/nextflow.config" | head -n 1)
PULL_ATTEMPTS="${PULL_ATTEMPTS:-3}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [container_tag] [images]"
    echo ""
    echo "Arguments:"
    echo "  container_tag: Image tag to pull (default: PIPELINE_VERSION, now $RELEASE_TAG)"
    echo "  images: Comma-separated list of images to pull, or 'all' (default: all; available: $ALL_IMAGES)"
    echo ""
    echo "Environment:"
    echo "  IMAGE_REGISTRY: Registry to pull from (default: ghcr.io/allenneuraldynamics)"
    echo "  IMAGE_DIR: Destination directory (default: $IMAGE_DIR)"
    echo "  FORCE: Set to 'true' to pull images that already exist in IMAGE_DIR"
    echo "  PULL_ATTEMPTS: Attempts per image before the script moves to the next image (default: 3)"
    exit 0
fi

CONTAINER_TAG_ARG="${1:-$RELEASE_TAG}"
IMAGES_ARG="${2:-all}"
[[ "$IMAGES_ARG" == "all" ]] && IMAGES_ARG="$ALL_IMAGES"

if [[ ! "$CONTAINER_TAG_ARG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "Error: invalid container tag '$CONTAINER_TAG_ARG'"
    exit 1
fi

if [[ ! "$PULL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: PULL_ATTEMPTS must be a positive integer, got '$PULL_ATTEMPTS'"
    exit 1
fi

if command -v apptainer >/dev/null 2>&1; then
    RUNTIME=apptainer
elif command -v singularity >/dev/null 2>&1; then
    RUNTIME=singularity
else
    echo "Error: neither apptainer nor singularity found in PATH"
    exit 1
fi

IFS=',' read -r -a IMAGES_LIST <<< "$IMAGES_ARG"

for image in "${IMAGES_LIST[@]}"; do
    if ! jq -e --arg i "$image" 'has($i)' "$IMAGES_JSON" >/dev/null; then
        echo "Error: unknown image '$image' (available: $ALL_IMAGES)"
        exit 1
    fi
done

umask 0002
mkdir -p "$IMAGE_DIR"

PARTIAL=""
FAILED=()
cleanup() {
    if [[ -n "$PARTIAL" ]]; then
        rm -f "$PARTIAL"
    fi
}
trap cleanup EXIT

echo "Images to pull: ${IMAGES_LIST[*]}"
echo "Container tag: $CONTAINER_TAG_ARG"
echo "Destination: $IMAGE_DIR"

for image in "${IMAGES_LIST[@]}"; do
    IMAGE_NAME=$(jq -r --arg i "$image" '.[$i].image_name' "$IMAGES_JSON")
    REF="$REGISTRY/$IMAGE_NAME:$CONTAINER_TAG_ARG"
    # Nextflow looks up this exact file name in NXF_SINGULARITY_LIBRARYDIR and NXF_APPTAINER_LIBRARYDIR.
    TARGET="$IMAGE_DIR/$(tr '/:' '--' <<< "$REF").img"
    if [[ -f "$TARGET" && "${FORCE:-false}" != true ]]; then
        echo "Skipping $image: $TARGET exists (set FORCE=true to pull again)"
        continue
    fi
    PARTIAL="$TARGET.pulling.$$"
    START=$SECONDS
    PULLED=false
    for (( attempt = 1; attempt <= PULL_ATTEMPTS; attempt++ )); do
        echo "Pulling $image image from $REF (attempt $attempt of $PULL_ATTEMPTS)"
        if "$RUNTIME" pull "$PARTIAL" "docker://$REF"; then
            chmod 0664 "$PARTIAL"
            mv -f "$PARTIAL" "$TARGET"
            PULLED=true
            echo "Pulled $image in $((SECONDS - START)) s"
            break
        fi
        rm -f "$PARTIAL"
        if (( attempt < PULL_ATTEMPTS )); then
            sleep 30
        fi
    done
    PARTIAL=""
    if [[ "$PULLED" != true ]]; then
        echo "Error: $image failed after $PULL_ATTEMPTS attempts"
        FAILED+=("$image")
    fi
done

if (( ${#FAILED[@]} > 0 )); then
    echo "Error: failed images: ${FAILED[*]}"
    exit 1
fi
