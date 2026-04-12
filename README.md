# QEMU with VirGL for Windows

This repository provides a Docker-based build system for cross-compiling QEMU with VirGL renderer support for Windows hosts.

## Dependencies

To build QEMU with WHPX (Windows Hypervisor Platform) support, the following headers from the Windows SDK are required:

- WinHvEmulation.h
- WinHvPlatform.h
- WinHvPlatformDefs.h

These headers are typically located at `C:\Program Files (x86)\Windows Kits\10\Include\<your_windows_version>\um` and should be copied to the folder with the Dockerfile.

To run QEMU with VirGL on Windows, the following ANGLE DLLs are required:

- libEGL.dll
- libGLESv2.dll
- d3dcompiler_47.dll

These DLLs can be obtained from Microsoft Edge or Google Chrome (located in their installation directories).

## Building QEMU

### Using Docker

1. Build the Docker image and load it into the local registry:
   ```bash
   # For Mac with Apple Silicon (M1/M2/M3/M4):
   docker buildx build --platform linux/arm64 -t qemu-virgl-win-cross --load .
   
   # For other platforms (Linux, Windows, Intel Mac):
   docker build -t qemu-virgl-win-cross .
   ```

2. Extract the built files to your local machine:
   ```bash
   mkdir -p ./output
   docker run --rm -v "$(pwd)/output:/mnt/output" qemu-virgl-win-cross
   ```

3. Copy the required ANGLE DLLs to the `output/bin` directory.

## Running QEMU with VirGL

### Creating a Virtual Machine

1. Create a disk image:
   ```
   ./output/qemu-img.exe create -f qcow2 vm-disk.qcow2 50G
   ```

2. Install Windows from an ISO:
   ```
   ./output/qemu-system-x86_64w.exe -M q35 -m 4G -cdrom windows.iso -hda vm-disk.qcow2 -device virtio-vga-gl -display sdl,gl=on
   ```

### Running Windows Guests with VirGL

For optimal 3D acceleration using VirGL:

```
./output/qemu-system-x86_64w.exe -M q35 -m 4G -hda windows.qcow2 -device virtio-vga-gl -display sdl,gl=on
```

Alternative command with explicit OpenGL ES mode:

```
./output/qemu-system-x86_64w.exe -M q35 -m 4G -hda windows.qcow2 -device virtio-vga-gl -display sdl,gl=es
```

**Note:** For Windows guests, you'll need to install VirtIO GPU drivers from the [VirtIO drivers ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/).

### Running Linux Guests with VirGL

Linux guests have excellent 3D acceleration support with VirGL, often better than Windows guests. Modern Linux distributions already include the necessary VirtIO GPU drivers.

1. Install a Linux distribution:
   ```
   ./output/qemu-system-x86_64w.exe -M q35 -m 4G -cdrom ubuntu.iso -hda linux.qcow2 -device virtio-vga-gl -display sdl,gl=on
   ```

2. Run an existing Linux VM with acceleration:
   ```
   ./output/qemu-system-x86_64w.exe -M q35 -m 4G -hda linux.qcow2 -device virtio-vga-gl -display sdl,gl=on -smp cores=4
   ```

### Using run-qemu.bat

The `output\run-qemu.bat` launcher script sets the correct `-L share` path and calls `bin\qemu-system-x86_64w.exe`. Run it from the `output\` directory and pass QEMU arguments directly:

```bat
cd output
.\run-qemu.bat -M q35 -m 8G -accel whpx -hda vm.qcow2 ^
  -device virtio-vga-gl -display sdl,gl=on ^
  -smp cores=4 -usb -device usb-tablet -k en-us ^
   -audiodev dsound,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 ^
  -device virtio-serial ^
  -chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on,mouse=off ^
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
```

This enables:
- **WHPX** hardware acceleration (requires Hyper-V/HypervisorPlatform enabled in Windows Features)
- **VirGL** 3D acceleration via SDL+OpenGL
- **Clipboard sync** between Windows host and Linux guest via `qemu-vdagent`

For clipboard sync to work in the guest, install and start `spice-vdagent`:
```bash
# Arch/EndeavourOS
sudo pacman -S spice-vdagent
systemctl --user enable --now spice-vdagentd

# Ubuntu/Debian
sudo apt install spice-vdagent
```

#### KDE Wayland guests — additional setup for reliable clipboard sync

On KDE Wayland, `spice-vdagent` monitors the X11 clipboard via XFixes rather than the
native Wayland clipboard. This means only the first guest→host copy works unless you
bridge the Wayland clipboard to X11. The following one-time setup makes every copy work:

1. **Configure spice-vdagent to use XFixes mode** (create/update the override):

   ```bash
   mkdir -p ~/.config/systemd/user/spice-vdagent.service.d
   cat > ~/.config/systemd/user/spice-vdagent.service.d/override.conf << 'EOF'
   [Service]
   ExecStart=
   ExecStart=/usr/bin/spice-vdagent -x
   Environment=DISPLAY=:1
   PassEnvironment=XAUTHORITY
   Restart=on-failure
   RestartSec=3s
   EOF
   ```

2. **Install clipboard bridge tools**:

   ```bash
   sudo pacman -S wl-clipboard xclip   # Arch/EndeavourOS
   # sudo apt install wl-clipboard xclip  # Ubuntu/Debian
   ```

3. **Create the bridge polling daemon**:

   ```bash
   mkdir -p ~/.local/bin
   cat > ~/.local/bin/wl-x11-cb.sh << 'EOF'
   #!/bin/bash
   # Polls Wayland clipboard every 0.3 s and mirrors it to X11 so that
   # spice-vdagent's XFixes watcher fires on every copy, not just the first.
   [ -z "$DISPLAY" ] && export DISPLAY=:1
   LAST=""
   while true; do
       sleep 0.3
       if [ -z "$XAUTHORITY" ]; then
           f=$(ls /run/user/1000/xauth_* 2>/dev/null | head -1)
           [ -n "$f" ] && export XAUTHORITY="$f"
           [ -z "$XAUTHORITY" ] && continue
       fi
       current=$(wl-paste --no-newline 2>/dev/null) || continue
       [ -z "$current" ] && continue
       [ "$current" = "$LAST" ] && continue
       LAST="$current"
       # Start new xclip; it takes X11 ownership immediately, causing the old
       # xclip to receive SelectionClear and exit — no manual kill needed.
       printf '%s' "$current" | xclip -selection clipboard -i -loops 0 &
   done
   EOF
   chmod +x ~/.local/bin/wl-x11-cb.sh
   ```

4. **Create and enable the bridge service**:

   ```bash
   cat > ~/.config/systemd/user/wl-x11-clip.service << 'EOF'
   [Unit]
   Description=Wayland to X11 clipboard bridge for spice-vdagent
   After=plasma-kwin_wayland.service graphical-session.target

   [Service]
   Type=simple
   ExecStartPre=/bin/bash -c 'for i in $(seq 30); do [ -S /run/user/1000/wayland-0 ] && exit 0; sleep 1; done; exit 1'
   ExecStart=%h/.local/bin/wl-x11-cb.sh
   Environment=WAYLAND_DISPLAY=wayland-0
   Environment=DISPLAY=:1
   Restart=on-failure
   RestartSec=5s

   [Install]
   WantedBy=graphical-session.target
   EOF

   systemctl --user daemon-reload
   systemctl --user enable wl-x11-clip
   systemctl --user start wl-x11-clip
   systemctl --user restart spice-vdagent
   ```

This bridge polls the Wayland clipboard every 300 ms. Each change starts a fresh
`xclip` process that takes X11 ownership, causing the previous xclip to exit via the
standard `SelectionClear` protocol — so XFixes fires reliably on every copy and
`spice-vdagent` sends a new GRAB each time.

#### Enabling clipboard debug logging

The clipboard code is compiled with debug logging disabled by default. To enable
verbose `warn_report` output for all clipboard events, set `SDL_CLIPBOARD_DEBUG 1`
in `patches/qemu-sdl-clipboard.patch` (near the top of the `ui/sdl2-clipboard.c`
section) and rebuild:

```diff
-#define SDL_CLIPBOARD_DEBUG 0
+#define SDL_CLIPBOARD_DEBUG 1
```

Then rebuild:

```bash
docker build --build-arg PATCH_CACHE_BUST=$RANDOM -t qemu-virgl-win-cross .
```

For optimal Linux guest experience:
- Use Ubuntu 20.04 or newer, Fedora 34+, or any recent distro with kernel 5.10+
- The Mesa drivers in these distributions have excellent VirtIO support
- 3D applications and desktop environments will automatically use hardware acceleration

To verify 3D acceleration is working in your Linux guest:
```bash
glxinfo | grep "OpenGL renderer"
```
The output should show "virgl" as the renderer.

## Optimization Options

- **Memory**: Adjust `-m 4G` to set the amount of RAM for the VM
- **CPU Cores**: Add `-smp cores=4` to specify the number of virtual CPU cores
- **Audio**: Add `-audiodev dsound,id=audio0 -device intel-hda -device hda-output,audiodev=audio0` for sound
- **Network**: Add `-nic user,hostfwd=tcp::3389-:3389` to enable RDP access

## Troubleshooting

If you encounter graphical issues:

1. Ensure all three ANGLE DLLs are in the same directory as the QEMU executable
2. Try the `-display sdl,gl=es` option which explicitly uses OpenGL ES mode
3. For older Windows versions, install the latest graphics drivers

## Advanced Options

For debugging or special use cases:

- Add `-enable-kvm` on Linux hosts for KVM acceleration
- Add `-accel whpx` on Windows hosts for Hyper-V acceleration
- Add `-monitor stdio` to access the QEMU monitor
- Add `-usb -device usb-tablet` for better mouse integration

## Credits

This build system is based on the work by [matthias-prangl](https://github.com/matthias-prangl).
