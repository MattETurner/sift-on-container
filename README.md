# SIFT Workstation on ARM64 (Apple Silicon / Apple Container)

This repository documents how to install the [SANS SIFT Workstation](https://github.com/teamdfir/sift-saltstack) on **Ubuntu 22.04 LTS (Jammy) ARM64**, targeting **Apple Silicon (M1/M2/M3/M4)** using **Apple’s container tool** (Apple Virtualization.framework-backed micro-VMs) instead of a full UTM VM.

## Important: this is a fork (container-first)
This repo is a **fork** to run SIFT via **Apple Container** rather than **UTM**.

- **Primary path:** build and run SIFT using this repo’s `Containerfile` (OCI-compatible) and `install.sh`.
- **Background:** the original effort (and many of the ARM64 notes below) came from VM-based installs; the key ARM64 fixes and package availability details still apply.

> The `install.sh` in this repository is forked from the upstream community work (commonly referred to as “sift-on-arm”) and adapted for this container-based workflow.

---

## Step-by-Step (Apple Container)

### Step 1: Install and Initialize Apple’s Container Tool
Since this uses Apple’s native Virtualization framework, install the official package and start the background service that manages the micro-VMs.

1. **Download and Install**
   - Go to the `apple/container` GitHub **Releases** page.
   - Download the latest signed `.pkg` installer.
   - Double-click to install.

2. **Start the Service**
   Open Terminal and start the background daemon:

   ```bash
   container system start
   ```

3. **Verify**

   ```bash
   container --version
   container system status
   ```

### Step 2: Boost the Builder VM Resources
When building a container image, Apple Container spins up a temporary **builder** micro-VM. The default is typically **2GB RAM**, which can cause the SIFT installer to hang or crash during image build. Increase the builder resources *before* building.

> Exact flags/commands can vary by Apple Container version. The goal is to set the builder VM to **at least 8GB RAM** (more is better) and adequate CPU.

Documented target:
- **RAM:** 8–12 GB
- **CPU:** 4+ cores
- **Disk:** ensure enough free space for the image layers (SIFT is large)

### Step 3: Build the SIFT Image (OCI)
This repository includes a `Containerfile` with OCI-compatible configuration to build an Ubuntu 22.04 ARM64 image and run the SIFT installer during the build.

From the repo root:

```bash
container build -f Containerfile -t <container name> .
```

### Step 4: Run the Container

```bash
container run --rm -it -v "${PWD}/evidence:/evidence" <container name> bash
```

---

## What Was Done (and Why It Was Hard)

### The Installer: CAST

SIFT no longer uses `sift-cli`. It uses [**Cast**](https://github.com/ekristen/cast) (v1.0.8), a Go-based single-binary installer that drives SaltStack under the hood. Cast does ship an `arm64` `.deb`.

Running `sudo cast install teamdfir/sift-saltstack` on ARM64 hit several issues that needed to be fixed before and during the run.

---

## Issues Encountered and Fixes Applied

### 1. `sift/repos/docker.sls` — YAML Rendering Failure

**Problem:** The original `docker.sls` caused a fatal SaltStack rendering error:
```
[CRITICAL] Rendering SLS 'base:sift.repos.docker' failed: could not find expected ':'; line 45
```
The Docker repo sources block did not specify an architecture, which caused a YAML parse conflict on ARM.

**Fix:** Added `Architectures: arm64` to the Docker apt sources block:
```yaml
sift-docker-repo:
  file.managed:
    - name: /etc/apt/sources.list.d/docker.sources
    - contents: |
        Types: deb
        URIs: https://download.docker.com/linux/ubuntu
        Suites: {{ grains['lsb_distrib_codename'] }}
        Components: stable
        Signed-By: /usr/share/keyrings/DOCKER-PGP-KEY.asc
        Architectures: arm64   # <-- added for ARM64
```

---

### 2. `sift/repos/ubuntu-universe.sls` — ARM64 Needs `ubuntu-ports`

**Problem:** On ARM64 Ubuntu 22.04, the universe/multiverse packages live at `ports.ubuntu.com/ubuntu-ports/`, not the standard `archive.ubuntu.com`. The original SLS only tried to enable the universe component on the default sources.
```
[CRITICAL] Rendering SLS 'base:sift.repos.ubuntu-universe' failed: could not find expected ':'; line 17
```

**Fix:** Added an ARM64 branch that appends the `ubuntu-ports` repository:
```jinja
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
sift-ubuntu-ports-repo-universe:
  file.append:
    - name: /etc/apt/sources.list.d/ubuntu.sources
    - text: |

        Types: deb
        URIs: http://ports.ubuntu.com/ubuntu-ports/
        Suites: jammy jammy-updates jammy-security jammy-backports
        Components: main universe restricted multiverse
        Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
        Architectures: arm64
    - unless:
      - grep -q "URIs: http://ports.ubuntu.com/ubuntu-ports/" /etc/apt/sources.list.d/ubuntu.sources
{% else %}
# ... original x86 logic ...
{%- endif %}
```

---

### 3. `sift/packages/radare2.sls` — ARM64 Binary Support

**Problem:** The original radare2 installer only downloaded the `amd64.deb`.

**Fix:** Added architecture detection to download the `arm64.deb` from the radare2 GitHub releases:
```jinja
{%- if grains["osarch"] == "aarch64" or grains["osarch"] == "arm64" -%}
{%- set hash = "c5b958a6ea59003431fd9f2117d71722f557db87b58e75dda17e072b1f9f50d3" -%}
{%- set filename = "radare2_" ~ version ~ "_arm64.deb" -%}
{%- else -%}
{%- set hash = "596c2b2e5cd95f38827f5e29d93547f7535e49c5bba0d5bd845b36f7e2488974" -%}
{%- set filename = "radare2_" ~ version ~ "_amd64.deb" -%}
{%- endif -%}
```

---

### 4. Microsoft Repo — amd64 Only

The Microsoft repo (`packages.microsoft.com`) is configured with `Architectures: amd64` — PowerShell is only available for x86-64. The SIFT SaltStack state already had a guard for this:
```jinja
- onlyif:
  - fun: match.grain
    tgt: 'osarch:amd64'
```
So PowerShell is **gracefully skipped** on ARM — no error, no action.

---

## ARM64 Package Status

### Recovered by `install.sh`

Several applications that were previously treated as non-functioning can work in the container when installed from Ubuntu Jammy ARM64 packages instead of the GIFT PPA package names expected by upstream SIFT states. The automated `install.sh` now installs these after Cast runs.

| Capability | Installed packages |
|---|---|
| Disk/filesystem forensics | `afflib-tools`, `autopsy`, `ewf-tools`, `sleuthkit`, `xmount` |
| Network/password tooling | `aircrack-ng` |
| libyal CLI utilities | `libbde-utils`, `libesedb-utils`, `libevt-utils`, `libevtx-utils`, `libfsapfs-utils`, `libfvde-utils`, `libmsiecf-utils`, `libolecf-utils`, `libregf-utils`, `libvmdk-utils`, `libvshadow-utils` |
| libyal Python bindings | Ubuntu `python3-lib*` dependencies pulled by `python3-dfvfs`/`python3-plaso` |
| Timeline tooling | `plaso`, `python3-plaso`, `python3-dfvfs`, `python3-tsk` |
| RAR extraction fallback | `unrar` |

### Still unavailable or intentionally skipped on Ubuntu 22.04 ARM64

These packages either do not have Ubuntu Jammy ARM64 packages, are absent from Ubuntu package indexes, or are intentionally amd64-only.

| Package | Impact |
|---|---|
| `aeskeyfind` | Ubuntu Jammy package is amd64-only |
| `bulk-extractor` | No Ubuntu package in Jammy/Noble/Questing package indexes; GIFT PPA path is amd64-oriented |
| `cmospwd` | x86-specific tool by nature (reads CMOS hardware) |
| `liblightgrep` | No Ubuntu Jammy package found |
| `rar` | RAR archive creation package is amd64-only; `unrar` is installed as the ARM64-safe extraction substitute |
| `powershell` | Microsoft's Linux packages are amd64-only; gracefully skipped by the installer |

---

## What Gets Installed (What Works on ARM64)

The vast majority of SIFT tools install and run correctly on ARM64:

- **Disk/filesystem forensics:** `sleuthkit`, `autopsy`, `testdisk`, `extundelete`, `scalpel`, `foremost`, `dc3dd`, `dcfldd`, `ewf-tools`, `afflib-tools`, `xmount`
- **Memory/registry:** `volatility3` (via pip), Ubuntu-native libyal libraries, Python bindings, and CLI utilities such as `regfinfo`, `vshadowinfo`, and related `*-utils` tools
- **Malware analysis:** `radare2`, `yara`, `ssdeep`, `upx-ucl`, `vbindiff`, `ghex`
- **Network forensics:** `wireshark`, `tcpflow`, `ngrep`, `ssldump`, `tcpreplay`, `scapy`
- **Password/crypto:** `hashdeep`, `samdump2`, `ophcrack`, `hydra`
- **Metadata:** `exiftool` (13.x, compiled from source), `exif`
- **General tools:** `docker`, `git`, `python3`, `jq`, `vim`, `wget`, `curl`, `netcat`, etc.

---

## Packaging / Automation

- `Containerfile`: OCI-compatible image definition used by Apple Container builds. It copies this repository's `install.sh` into the image and executes it as root during the build.
- `install.sh`: the integrated ARM64 container installer. It owns package bootstrap, Cast installation, SIFT SaltStack patching, known ARM64 partial-failure handling, and installation of Ubuntu ARM64 recovery packages.

---

## Contributing / Issues

The ARM64 fixes in the SaltStack states should ideally be upstreamed to [teamdfir/sift-saltstack](https://github.com/teamdfir/sift-saltstack). The key PRs needed are:

1. Fix `docker.sls` for ARM64 architecture pin
2. Fix `ubuntu-universe.sls` for ARM64 ports repository
3. Add ARM64 support to `radare2.sls` (may already be merged upstream)

If you find additional packages that need ARM64 fixes, please open an issue here or upstream.
