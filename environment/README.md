# Step images

Each pipeline step runs in its own `linux/amd64` image. An image holds the dependencies of the
step's processing library, not the library itself: each task clones the library at the commit in
`pipeline/process_versions.env` and installs it with `--no-deps`, so a library change that keeps
its dependencies needs no rebuild.

| File | Purpose |
| --- | --- |
| `../pipeline/images.json` | Step name to Dockerfile, image name and Python version; it sits in `pipeline/` because the pipeline reads it at run time |
| `Dockerfile_python` | Image for every step except extraction |
| `Dockerfile_extraction` | Extraction image: a conda CaImAn environment plus a pip overlay |
| `stages/<step>/requirements.in` | The library's declared dependencies, written by `lock.py` |
| `stages/<step>/requirements.lock` | Resolved dependency versions built into the image |
| `stages/<step>/build.constraints` | Build tool and NumPy versions used to build wheels |
| `stages/extraction/conda-*`, `overlay-policy.json`, `overrides.in` | The extraction conda lock and the pip packages allowed to replace conda ones |
| `builder-requirements.txt` | pip, setuptools, setuptools-scm, packaging, tomli and wheel, used to build wheels; the setuptools, setuptools-scm, packaging and tomli pins are also installed in `/opt/build-tools`, which tasks use to install the processing library |
| `runtime-check.py` | Import checks run while building each image |
| `lock.py` | Writes `requirements.in` and resolves `requirements.lock` for one or more steps |
| `build_all.sh`, `push_all.sh` | Build images into the local Docker daemon, and push them |
| `pull_all.sh` | Pull images from the registry as Singularity/Apptainer files into a shared directory |
| `resolve-extraction-conda.py`, `conda-overlay-check.py` | Resolve the extraction conda lock; check the pip overlay at build time |

## Re-lock after a dependency change

```bash
uv run --python 3.12 --no-project environment/lock.py DFF        # or: all
git diff environment/stages/dff/requirements.lock
```

`lock.py` reads the library repository and commit from `pipeline/process_versions_custom.env`
when it exists, otherwise from `pipeline/process_versions.env`. The resolver keeps the versions
already in the lock wherever the library's dependencies allow, and pins CPU PyTorch wheels by URL
and hash for every step except the classifier. To re-solve the extraction conda layer, run
`uv run --python 3.12 --no-project environment/resolve-extraction-conda.py --micromamba /path/to/micromamba`
before `lock.py EXTRACTION`.

## Build and push

```bash
environment/build_all.sh <tag> [main|dev] [STEP,STEP|all]
environment/push_all.sh <tag> [main|dev] [STEP,STEP|all]
```

`build_all.sh` loads each image into the local Docker daemon as
`$IMAGE_REGISTRY/<image_name>:<tag>` (default registry `ghcr.io/allenneuraldynamics`); `dev` appends
`-dev` to the tag. `push_all.sh` pushes them, and with `main` also tags them `latest`. Run every
step with one tag with `--container_tag <tag>`, or name individual images in
`pipeline/images_custom.env`.

In CI, pull requests and pushes into `dev` build every image with the `dev` tag, skipping a step
whose image already carries the same build-input hash (`.github/scripts/image_info.sh`). The release
pull request into `main` checks the `dev` images match its head, and after each release they are
promoted to the new version and `latest`.

## Pull for SLURM

```bash
environment/pull_all.sh [tag] [STEP,STEP|all]
```

`pull_all.sh` pulls each image from `$IMAGE_REGISTRY` with Apptainer or Singularity into
`$IMAGE_DIR` (default `/n/holylfs06/LABS/kempner_shared/Everyone/workflow/ophys-roi-extraction-2026/images`).
The tag defaults to `PIPELINE_VERSION` in `pipeline/nextflow.config`. Each file has the name that
Nextflow gives its image cache, for example `ghcr.io-allenneuraldynamics-pophys-dff-4.0.0.img`, so a
SLURM run uses the files without a pull when `NXF_SINGULARITY_LIBRARYDIR` (or
`NXF_APPTAINER_LIBRARYDIR` for Apptainer) points to that directory. The script skips files that
already exist; set `FORCE=true` to pull them again, for example for the `dev` tag. Each image gets
`PULL_ATTEMPTS` attempts (default 3); an image that still fails does not stop the others, and the
script exits non-zero with the list of failed images. Run it on a compute node, with
`SINGULARITY_CACHEDIR` and `SINGULARITY_TMPDIR` on node-local disk: on NFS, unpacking is slow and
the temporary folder cannot be removed.

`environment/pull_all.sbatch` is an example job. On compute nodes where each internet connection
is slow and drops after a few minutes, `singularity pull` cannot finish a large layer because it
cannot resume one. The job therefore first downloads each layer with `aria2c` (8 connections,
resumable), checks its SHA-256, and moves it into the node-local Singularity cache, so the pull
reuses it. The job skips images whose files already exist unless `FORCE=true`.
