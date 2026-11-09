# ROCm box

An Ubuntu machine with a Radeon card that you SSH into from your PC, for HIP and ROCm work. The scripts were written for an RX 7600, and the steps apply to other cards ROCm 10.1 supports. The box also does two other jobs:

- **A free rehearsal of the droplet setup.** It runs the same OS (Ubuntu 24.04), the same ROCm (10.1) and the same Lemonade package as the MI300X droplet.
- **A local Radeon test bed for Lemonade.**

**Untested:** none of this has run on real hardware yet.

## Why a separate box rather than a card in your main PC

- HIP code compiles without an AMD GPU. You need the card only to run it.
- ROCm's main platform is Linux. A Radeon card beside an NVIDIA one in a Windows PC mixes two vendors' drivers on your main machine.
- A box that matches the droplet lets you find setup problems before you pay $1.99/hour.

## The RX 7600

- The RX 7600 is gfx1102 (RDNA 3) with 8 GB of VRAM.
- ROCm 10.1's compatibility matrix lists it, on Ubuntu 24.04.5 with the HWE 7.0 kernel.
- Lemonade's llama.cpp ROCm backend covers it (gfx110X).
- 8 GB limits you to small models. `Qwen3.5-4B-GGUF` (3.6 GB) fits; the 23 GB default model doesn't.

## Build the box

1. **BIOS:** turn on "Above 4G Decoding", which AMD lists as a prerequisite, and Resizable BAR if the board offers it. Turn Secure Boot off; otherwise the driver needs a key enrolled at boot.
2. **Ubuntu:** install Ubuntu Server 24.04.5. In the installer, enable the OpenSSH server and add your key (`~\.ssh\id_ed25519.pub` on your PC).
3. **Network:** give the box a fixed address, for example a DHCP reservation on your router.

## Set it up from your PC

From the Leasehold folder:

```powershell
.\leasehold.ps1 rocm -Ip <box-ip> -User <your-login>
```

`sudo` will ask for your password. `setup-rocm-box.sh` takes up to three runs, and each tells you whether to reboot before the next:

1. Installs the HWE kernel, if the box isn't already on 7.0 or newer.
2. Installs AMD's driver and ROCm 10.1 with `amdgpu-install --usecase=rocm,graphics --gfxversion=auto`, and adds you to the `render` and `video` groups.
3. Checks everything: `rocminfo`, `amd-smi`, then builds and runs `hip-smoke/vector_add.hip`, which prints the GPU and its wavefront size and checks 16M additions.

To reboot: `.\leasehold.ps1 ssh -User <your-login>`, then `sudo reboot`.

## Rehearse the droplet setup

```powershell
.\leasehold.ps1 setup -User <your-login> -Model Qwen3.5-4B-GGUF
.\leasehold.ps1 tunnel -User <your-login>
```

Then, from your project folder, `leasehold.ps1 pi -Model Qwen3.5-4B-GGUF`. The setup script will warn that the GPU isn't gfx942, which is expected here.

## HIP notes

- **Wavefront size:** RDNA (this card) runs 32-wide wavefronts, while CDNA (the MI300X) runs 64-wide. Kernels that hard-code either size break on the other, so read `warpSize`. The smoke test prints it.
- **Cross-compiling for the MI300X:** that needs the gfx942 target package, `sudo apt install amdrocm10.1-gfx942`. The script tries it and skips it if the package is missing.
- **Running HIP from Windows:** AMD also ships ROCm as pip wheels for Windows. You could compile there, but without an AMD GPU in the PC nothing would run, so this box is the place for HIP work.
