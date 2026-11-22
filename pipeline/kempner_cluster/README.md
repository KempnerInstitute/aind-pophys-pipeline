# Pophys pipeline on the Kempner AI cluster

This folder runs the pophys pipeline on the Kempner partitions of the FASRC cluster. It is a copy of
`pipeline/` with a Kempner SLURM configuration, two job scripts and an environment file. The example
is the public single-plane session `single-plane-ophys_869385_2026-11-07_12-33-14` (36.6 GiB).

For a single-plane session the steps are: Converter, Motion correction, Movie QC, Extraction, dF/F,
Classifier (GPU), Event detection, NWB packaging and Metadata aggregation. Each step runs as its own
SLURM job. A head job runs Nextflow and submits the steps.

## Files

| File | Purpose |
| --- | --- |
| `main.nf`, `images.json`, `process_versions.env`, `nextflow.config` | Unchanged copies from `pipeline/` |
| `nextflow_slurm.config` | Kempner SLURM configuration (see "Changes from pipeline/") |
| `slurm_submit.sh`, `preflight.sh`, `run_local.sh` | Copies from `pipeline/`; default paths point to the repository root |
| `kempner_run.env.example` | All run settings; copy it to `kempner_run.env` |
| `prepare_inputs.sbatch` | Creates the Nextflow environment if it is missing, downloads the model files and the session, upgrades a v1 `data_description.json` |
| `upgrade_data_description.py` | Upgrades a v1 `data_description.json` to v2 (run by `prepare_inputs.sbatch`) |
| `run_single_plane.sbatch` | Head job that runs the pipeline |

## 1. Connect to the cluster

```bash
ssh <username>@login.rc.fas.harvard.edu
git clone https://github.com/AllenNeuralDynamics/aind-pophys-pipeline.git
```

## 2. Make a run directory and the environment file

Both job scripts read `kempner_run.env` from the directory where you run `sbatch`. That directory
also holds Nextflow's run history, which `-resume` needs.

```bash
mkdir -p /path/to/run && cd /path/to/run
cp /path/to/aind-pophys-pipeline/pipeline/kempner_cluster/kempner_run.env.example kempner_run.env
cp /path/to/aind-pophys-pipeline/pipeline/kempner_cluster/*.sbatch .
```

Edit `kempner_run.env`. All paths must be absolute.

| Variable | Description |
| --- | --- |
| `DEFAULT_ACCOUNT` | SLURM account for every step |
| `DEFAULT_QUEUE` | Partition for the CPU steps (default `shared`) |
| `GPU_QUEUE` | One partition for the Classifier step (default `kempner`) |
| `GPU_CLUSTER_OPTIONS` | GPU request for the Classifier step (default `--gres=gpu:1`) |
| `NEXTFLOW_ENV` | Conda environment with Nextflow 24.10.4 and OpenJDK 17 |
| `NXF_SINGULARITY_LIBRARYDIR` | Folder with the step images (`.img` files) |
| `PIPELINE_PATH` | This folder |
| `PARAMS_FILE` | Parameter file, for example `pipeline_parameters.json` at the repository root |
| `DATA_PATH` | Model files folder, mounted in every task at `/tmp/data` |
| `SESSION`, `SESSIONS_DIR` | Session name in `s3://aind-open-data`, and the folder that receives it |
| `ACQUISITION_DATA_TYPE` | `single` or `multiplane` |
| `RESULTS_PATH` | Output folder |
| `WORKDIR` | Nextflow work folder, on storage that all nodes can reach |

Partitions: all Kempner partitions are GPU nodes, and they reject jobs that do not request a GPU.
So the head job and the CPU steps run on `shared`, and only the Classifier step runs on a Kempner
GPU partition (`kempner`, A100). `GPU_QUEUE` must name one partition: the cluster rejects a
comma-separated list. Set `DEFAULT_ACCOUNT` to your SLURM account, and also set
`#SBATCH --account` in the two job scripts.

## 3. Prepare the inputs

```bash
sbatch prepare_inputs.sbatch
```

The job runs on a CPU partition and does three things:

1. If `NEXTFLOW_ENV` does not exist, it creates it with `conda` (`nextflow=24.10.4`, `openjdk=17`).
   The cluster's own Java (1.8) and the `jdk/25` module are outside the range that Nextflow
   24.10.4 supports (17 to 23).
2. It downloads the model files (about 273 MB) to `DATA_PATH` and checks them with `SHA256SUMS`.
   Files that already pass the check are not downloaded again.
3. It downloads the session from `s3://aind-open-data` with `aria2c` and compares it with the
   bucket (`rclone check`). Files that are already complete are skipped, so you can submit the job
   again after a time-out.
4. If the session's `data_description.json` uses aind-data-schema v1 (for example the example
   session, schema 1.0.4), it upgrades the file to v2 with `aind-metadata-upgrader` inside the
   aggregator image (`upgrade_data_description.py`) and keeps the original as
   `data_description.json.v1`. The Metadata aggregation step reads this file with the v2 model only
   and fails on a v1 file. The job restores the original before it checks the session again.

Each compute-node connection to S3 gets only about 0.3 MiB/s, and long connections can drop. `aria2c`
downloads 8 files at a time with 16 connections each, in 8 MiB segments, and fetches a dropped
segment again on its own. A plain `rclone copy` reached only 2.4 MiB/s. Do not give the pipeline an
S3 URL for `--ophys_mount_url`: Nextflow would copy the session through one slow connection.

## 4. Run the pipeline

```bash
sbatch run_single_plane.sbatch
```

The head job runs `slurm_submit.sh`, which runs `preflight.sh` and then Nextflow with
`nextflow_slurm.config`. It always adds `-resume`: after a failure, fix the cause and submit the
same job again from the same run directory; finished steps are not run again. After Nextflow
ends, the job merges every step's results into `RESULTS_PATH` (see "Troubleshooting").

Monitor the run:

```bash
squeue -u $USER                          # head job and step jobs (named nf-<n>, n counts tasks per step)
tail -f head-<jobid>.out                 # Nextflow progress
less $RESULTS_PATH/nextflow/nextflow.log # full Nextflow log
```

A failed step's output is `.command.log` in the work folder that the error message names.

## 5. Results

```text
RESULTS_PATH/
├── plane_0/
│   ├── plane_0.h5         (converted movie)
│   ├── motion_correction/
│   ├── movie_qc/
│   ├── extraction/
│   ├── dff/
│   ├── classification/
│   └── events/
├── nwb/
│   ├── pophys.nwb.zarr/   (NWB file in Zarr format)
│   └── processing.json
├── pophys.nwb.zarr        (link to nwb/pophys.nwb.zarr)
├── nextflow/              (report.html, timeline.html, trace.txt, dag.html, nextflow.log)
├── processing.json
├── quality_control.json
├── data_description.json
└── session.json, rig.json, subject.json, procedures.json
```

See `docs/source/input_output.rst` for the files in each folder. The NWB step writes
`pophys.nwb.zarr` at the results root; the head job moves it into `nwb/`, as the docs describe,
and leaves a link at the root, where the run-level `processing.json` points. For the example
session the results take
49 GB, mostly `plane_0.h5` and the registered movie. After you check the results, delete
`WORKDIR`; it holds every intermediate file.

## 6. Step images

The 11 step images for tag 4.0.0 are in
`/n/holylfs06/LABS/kempner_shared/Everyone/workflow/ophys-roi-extraction-2026/images`, with the
file names that Nextflow expects. To pull another tag, use `environment/pull_all.sbatch`.

## Troubleshooting

- A step fails with `[Errno 39] Directory not empty: 'build/bdist...'` while it installs its
  processing library: setuptools cannot build some libraries (for example the dF/F library) in a
  work folder on NFS. `scratch = '/scratch'` in `nextflow_slurm.config` runs every step on
  node-local disk; keep it.
- The Classifier fails with `CUDA error: CUDA-capable device(s) is/are busy or unavailable`: the GPU
  that SLURM gave the job is faulty. A plain CUDA program on that node fails in the same way
  (`cuDevicePrimaryCtxRetain` returns 999). Find the node with `sacct -j <jobid> -o NodeList`,
  exclude it with `GPU_CLUSTER_OPTIONS="--gres=gpu:1 --exclude=<node>"`, report it to FASRC, and
  submit the head job again. A faulty GPU frees itself at once, so new jobs keep landing on it.

- The Metadata aggregation step fails with `validation errors for DataDescription` (`modalities`
  field required, `modality`, `platform`, `label` not permitted): the session has a v1
  `data_description.json`. Run `prepare_inputs.sbatch` again; it upgrades the file. All steps run
  again after the upgrade, because every step reads the session JSON files.
- `RESULTS_PATH/plane_0` holds only one step folder (for example `events/`): every step also
  outputs its whole plane folder, so Nextflow's `publishDir` drops the nested step files as
  duplicates and each step's plane folder replaces the previous one. This is a `main.nf` issue on
  SLURM and local runs. `run_single_plane.sbatch` fixes the result after Nextflow ends: it lists
  the run's tasks with `nextflow log last` and merges each task's `capsule/results` into
  `RESULTS_PATH` with `rsync`. To repair an older run, submit the head job again; `-resume`
  reuses all steps and the merge runs.

## Changes from pipeline/

- `nextflow_slurm.config`:
  - CPU steps on `shared` and the Classifier on `kempner`, with `--account` from
    `DEFAULT_ACCOUNT` (default `kempner_dev`) on every step
  - Classifier: account plus `GPU_CLUSTER_OPTIONS` (default `--gres=gpu:1`), partition `GPU_QUEUE`
  - `scratch = '/scratch'`: every step runs on node-local disk and copies its outputs back
  - `libraryDir` set from `NXF_SINGULARITY_LIBRARYDIR` (default: the shared image folder), so no
    task pulls an image
  - step jobs named `nf-<n>`, because SLURM job names are visible to all users
  - `DATA_PATH` fallback `../../data` (the repository root)
- `slurm_submit.sh`, `preflight.sh`, `run_local.sh`, `nextflow_local.config`: default paths point to
  the repository root (`../../`), because this folder is one level deeper than `pipeline/`.
