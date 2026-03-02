<!-- Copied into repo by AI: concise, actionable guidance for code-assistant agents -->
# Copilot instructions for qemu-virgl-winhost

Purpose: help AI coding agents be immediately productive in this repository.

- **Big picture:** This project cross-compiles QEMU (x86_64 softmmu) for Windows hosts with VirGL renderer support using a Docker-based Mingw toolchain. The build happens inside the `Dockerfile` which installs mingw64 toolchain, meson/ninja, and builds libepoxy, virglrenderer and QEMU. See [README.md](README.md) and [Dockerfile](Dockerfile).

- **Major components:**
  - QEMU source: cloned and built inside the Docker image (see `git clone https://github.com/qemu/qemu.git` in `Dockerfile`).
  - Virgl renderer: downloaded and built in the image (`virglrenderer` step).
  - ANGLE headers + DLLs: headers are provided under `angle/include`; runtime DLLs (`libEGL.dll`, `libGLESv2.dll`, `d3dcompiler_47.dll`) are required and must be copied into `output/bin` locally (see README "Dependencies").
  - Windows WHPX headers: `WinHvEmulation.h`, `WinHvPlatform.h`, `WinHvPlatformDefs.h` — these are required from the Windows SDK and are copied into the cross sys-root in the Dockerfile.

- **Key files to read first:**
  - [README.md](README.md) — build and run quickstart, docker build commands and runtime invocation examples.
  - [Dockerfile](Dockerfile) — canonical build steps, packages installed, and where files are copied into the cross sys-root. Use it to discover required packages, meson/ninja usage, and config flags.
  - [WinHvPlatform.h](WinHvPlatform.h) and [WinHvEmulation.h](WinHvEmulation.h) — required Windows API headers (copied into the image by the Dockerfile). Useful when touching WHPX/WinHv interop.
  - [angle/include/EGL/README.md](angle/include/EGL/README.md) — explains how the EGL headers were generated and how to regenerate them.

- **Build & dev workflows (explicit):**
  - Standard build: follow [README.md](README.md) Docker steps. Examples pulled from README:

```bash
# Mac M1/M2/etc:
docker buildx build --platform linux/arm64 -t qemu-virgl-win-cross --load .

# Other platforms:
docker build -t qemu-virgl-win-cross .

# Extract artifacts:
mkdir -p ./output
docker run --rm -v "$(pwd)/output:/mnt/output" qemu-virgl-win-cross
```

  - The Dockerfile installs `meson`/`ninja` and uses `mingw64-meson` for cross builds. When changing build logic, update both the Dockerfile commands and any meson options used there (search for `mingw64-meson`, `ninja`, and the `./configure` flags in the Dockerfile).
  - **Parallelism:** `BUILD_JOBS` defaults to `4`; override at build time with `--build-arg BUILD_JOBS=8` for faster iteration. (`BUILD_JOBS` is declared as both `ARG` and `ENV` in the Dockerfile so `--build-arg` works.)
  - **CI:** `.github/workflows/docker-build.yml` runs `docker/build-push-action` on every push/PR to `main`/`master`, uses a local layer cache keyed on `${{ github.sha }}`, and uploads extracted artifacts for 14 days. ANGLE DLLs are absent from the artifact — add them manually before running.
  - **ccache:** The image wires ccache into `PATH` (`/usr/lib/ccache`) and stores the cache at `CCACHE_DIR=/ccache`. Mount a host volume at `/ccache` to persist the cache across `docker build` runs and dramatically cut rebuild times:
    ```bash
    docker build --build-arg BUILDKIT_INLINE_CACHE=1 \
      -v "$(pwd)/.ccache:/ccache" \
      -t qemu-virgl-win-cross .
    ```

- **Repository-specific conventions & patterns:**
  - Cross-compile target binaries are placed into `OUTPUT_DIR` inside the image and copied to `./output/bin` by the Dockerfile; runtime examples call `./output/qemu-system-x86_64w.exe`.
  - The Dockerfile patches QEMU source in two ways: (1) inline `sed` on `ui/sdl2.c` to guard ANGLE SDL hints, and (2) `patch -p1` applying files from the `patches/` directory. Current patches: `qemu-10.1.2-sdl-clipboard.patch` (adds SDL clipboard sync between host and guest via `ui/sdl2-clipboard.c`). To add a new patch, drop it in `patches/` and add a `patch -p1 < /patches/<name>.patch` line in the QEMU `RUN` block before `./configure`.
  - Headers from `angle/include/` are intentionally copied into the sys-root pkgconfig/include location inside the Docker image; if modifying angle headers, update the `COPY` lines in `Dockerfile`.
  - Use meson options already present: `-Dplatforms=egl`, `-Degl=yes`, `-Dglx=no`, etc. Mirror these when adding or changing renderer options.

- **Integration points & external dependencies:**
  - Windows SDK headers (WHv*) must be sourced from a Windows machine and placed alongside the Dockerfile so the Docker build can COPY them into the cross sys-root.
  - ANGLE runtime DLLs must be obtained from official browsers and manually placed into `output/bin` after build (see README). They are not built by this repo.
  - External repos used at build-time: libepoxy (git clone HEAD), virglrenderer **main branch** (tarball from freedesktop GitLab), and upstream QEMU (git clone HEAD). All version pins live in `Dockerfile` — grep for `virglrenderer-main.tar.gz` to find the tarball URL.
  - **ANGLE pkgconfig stubs:** `angle/egl.pc` and `angle/glesv2.pc` declare version `18.2.8` and point at the mingw sys-root. They are `COPY`-ed into `/usr/x86_64-w64-mingw32/sys-root/mingw/lib/pkgconfig/` so that meson/cmake dependency lookups resolve ANGLE without a real build of ANGLE.

- **What to change & how to test locally:**
  - Small code edits (C/C++): edit sources under local checkout, then rebuild inside the Docker image. Use `docker run` to extract outputs and test with the QEMU commands in README.
  - Regenerating EGL headers: follow [angle/include/EGL/README.md](angle/include/EGL/README.md) (requires Python 3 + lxml, clone KhronosGroup/EGL-Registry, run `genheaders.py`, copy result, and update `scripts/egl.xml`).
  - Regenerating GLES 1.x headers: follow [angle/include/GLES/README.md](angle/include/GLES/README.md) (same toolchain; clone KhronosGroup/OpenGL-Registry instead, update `scripts/gl.xml`).
  - `scripts/egl.xml` and `scripts/gl.xml` are the Khronos registry XML snapshots used as inputs to the header generators — keep them in sync when updating headers.

- **Examples of useful quick searches for agents:**
  - Search for `COPY WinHv*.h` in [Dockerfile](Dockerfile) to find where WHv headers are used.
  - Search for `virglrenderer` or `libepoxy` to find build steps and meson invocations.
  - Search for `virtio-vga-gl` or `-device virtio-vga-gl` in README to find runtime usage.

- **Do not assume:**
  - Do not assume ANGLE DLLs are built here — they must be provided externally.
  - Do not assume Windows SDK headers are present in CI — builds will fail unless the three WHv headers are provided to the Docker context.

If any of this is unclear or you want stricter rules (coding style, commit hooks, or automated CI steps), tell me which area to expand and I'll iterate.
