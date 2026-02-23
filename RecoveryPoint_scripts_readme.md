# Recovery Point Scripts Guide

This document explains the purpose of:

- `rp_ia_client.sh`
- `rp_ia_module.sh`

and shows how to install prerequisites on Ubuntu and run the scripts to create a recovery point for disks attached to a VM.

---

## What each file does

## `rp_ia_module.sh` (library)

Reusable Bash module with helper functions for Azure REST operations related to Restore Point Collections (RPC) and Restore Points (RP).

Main responsibilities:

- Builds Azure Resource Manager URLs and appends `api-version`
- Gets Azure access token via `az account get-access-token`
- Sends REST requests with `curl`
- Handles retries/backoff for transient HTTP errors (`408`, `409`, `429`, `5xx`)
- Exposes helper functions for:
  - create/update restore point collection
  - create/update restore point
  - get restore point
  - get restore point instance view

Use this file by sourcing it:

```bash
source ./rp_ia_module.sh
```

## `rp_ia_client.sh` (entrypoint CLI)

User-facing script that parses arguments and calls module functions.

Commands:

- `run-all` (default):
  1. create/update RPC
  2. create/update RP
  3. get RP details
- `rpc`: create/update restore point collection only
- `rp`: create/update restore point only
- `get`: get restore point details only
- `instance-view`: get restore point instance view only

Key behaviors:

- Appends UTC timestamp to restore point name for create operations
- Supports app-consistent mode by default (or crash-consistent with `--consistency-mode CrashConsistent`)
- Supports disk exclusions:
  - `--exclude-os-disk`
  - `--exclude-data-disk <diskNameOrDiskId>` (repeatable)
- Writes metadata JSON after RP creation (`<rp-name>.metadata.json` by default)

---

## Install on Ubuntu

## 1) Install prerequisites

```bash
sudo apt-get update
sudo apt-get install -y curl jq ca-certificates apt-transport-https lsb-release gnupg
```

Install Azure CLI (Microsoft package flow):

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

Verify:

```bash
az version
bash --version
curl --version
```

## 2) Copy scripts to the server

Example:

```bash
mkdir -p ~/azure-rp
cd ~/azure-rp
# copy rp_ia_client.sh and rp_ia_module.sh here
```

## 3) Make scripts executable

```bash
chmod +x rp_ia_client.sh rp_ia_module.sh
```

## 4) Authenticate to Azure

```bash
az login
```

If needed, select subscription:

```bash
az account set --subscription <subscription-id>
```

---

## Gather required values

You need these values before running:

- Subscription ID
- Resource group name
- Restore point collection name (new or existing)
- Restore point base name
- Region (location)
- Source VM ARM ID

Get source VM ARM ID:

```bash
az vm show -g <resource-group> -n <vm-name> --query id -o tsv
```

Optional: export as environment variables (supported by the script):

```bash
export AZURE_SUBSCRIPTION_ID="<subscription-id>"
export AZURE_RESOURCE_GROUP="<resource-group>"
export AZURE_RESTORE_POINT_COLLECTION="<rpc-name>"
export AZURE_RESTORE_POINT_NAME="<rp-base-name>"
export AZURE_LOCATION="<region>"
export AZURE_SOURCE_VM_ID="<source-vm-arm-id>"
export AZURE_INSTANT_ACCESS_DURATION_MINUTES="120"
```

---

## Create a recovery point for attached VM disks

## Option A (recommended): one command with `run-all`

```bash
./rp_ia_client.sh run-all \
  --subscription-id <subscription-id> \
  --resource-group <resource-group> \
  --rpc-name <rpc-name> \
  --rp-name <rp-base-name> \
  --location <region> \
  --source-vm-id <source-vm-arm-id> \
  --duration-minutes 120
```

What happens:

1. RPC is created/updated for the source VM
2. RP is created with a timestamped name, e.g. `<rp-base-name>-20260224153010`
3. Script waits for provisioning success (unless `--no-wait`)
4. RP details are fetched
5. Metadata file is written in current directory

## Option B: step-by-step

Create/update collection:

```bash
./rp_ia_client.sh rpc \
  --subscription-id <subscription-id> \
  --resource-group <resource-group> \
  --rpc-name <rpc-name> \
  --location <region> \
  --source-vm-id <source-vm-arm-id>
```

Create restore point:

```bash
./rp_ia_client.sh rp \
  --subscription-id <subscription-id> \
  --resource-group <resource-group> \
  --rpc-name <rpc-name> \
  --rp-name <rp-base-name> \
  --duration-minutes 120
```

Get restore point details:

```bash
./rp_ia_client.sh get \
  --subscription-id <subscription-id> \
  --resource-group <resource-group> \
  --rpc-name <rpc-name> \
  --rp-name <full-rp-name>
```

---

## Disk inclusion/exclusion behavior

By default, restore point includes OS + all attached data disks.

To exclude disks:

- Exclude OS disk:

```bash
./rp_ia_client.sh rp ... --exclude-os-disk
```

- Exclude one or more data disks (repeat flag):

```bash
./rp_ia_client.sh rp ... --exclude-data-disk datadisk1 --exclude-data-disk datadisk2
```

`--exclude-data-disk` accepts either:

- data disk name on the source VM, or
- full disk resource ID

---

## Useful runtime options

- `--no-wait`: return immediately after RP request
- `--poll-seconds <int>`: polling interval when waiting
- `--metadata-file <path>`: custom output path for metadata JSON
- `--log-file <path>`: write output to log file
- `--debug`: verbose request/polling logs

Example with debug + log file:

```bash
./rp_ia_client.sh run-all \
  --subscription-id <subscription-id> \
  --resource-group <resource-group> \
  --rpc-name <rpc-name> \
  --rp-name <rp-base-name> \
  --location <region> \
  --source-vm-id <source-vm-arm-id> \
  --duration-minutes 120 \
  --debug \
  --log-file ./rp_ia_client.log
```

---

## Quick validation

After creation, confirm the RP exists:

```bash
az restore-point show \
  --subscription <subscription-id> \
  -g <resource-group> \
  --collection-name <rpc-name> \
  -n <full-rp-name> \
  --query "{name:name,state:provisioningState,consistency:properties.consistencyMode}" -o json
```

If successful, you now have a restore point representing the selected disks for that VM at that timestamp.
