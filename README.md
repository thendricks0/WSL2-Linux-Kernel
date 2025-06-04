# WSL2 Linux Kernel Builder
[![Build Kernel](https://github.com/thendricks0/WSL2-Linux-Kernel/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/thendricks0/WSL2-Linux-Kernel/actions/workflows/build-kernel.yml)

This repo contains a workflow to build the latest WSL2 Linux kernels from source and provide a neat little installer to install them on your WSL2 instance.

The workflow runs nightly so any kernel updates should be available in about 24 hours after they are released.

## Usage

Run the following command in your PowerShell terminal:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/thendricks0/WSL2-Linux-Kernel/ci/Install-WSL2Kernel.ps1'))
```

This will present you with a menu to select your desired kernel version. After selecting a version, it will download the kernel and install it on your WSL2 instance.
