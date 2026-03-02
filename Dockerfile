# syntax=docker/dockerfile:1
FROM fedora:latest

# Define build arguments and environment variables
ARG OUTPUT_DIR=/output
ENV OUTPUT_DIR=${OUTPUT_DIR}

# Set optimal number of build jobs based on available cores (override with --build-arg BUILD_JOBS=N)
ARG BUILD_JOBS=4
ENV BUILD_JOBS=${BUILD_JOBS}

RUN --mount=type=cache,target=/var/cache/dnf \
    dnf update -y && \
    dnf install -y mingw64-gcc \
                mingw64-glib2 \
                mingw64-pixman \
                mingw64-gtk3 \
                mingw64-SDL2 \
                git \
                make \
                flex \
                bison \
                python \
                python3-pyyaml \
                autoconf \
                automake \
                libtool \
                pkg-config \
                xorg-x11-util-macros \
                meson \
                ninja-build \
                mingw64-meson \
                mingw64-cmake \
                cmake \
                ccache \
                diffutils \
                patch \
                python3-pip \
                rust \
                cargo \
                mingw64-SDL2_image \
                mingw64-openssl \
                mingw64-opus \
                mingw64-libjpeg-turbo \
                mingw64-lz4 \
                mingw64-zlib \
                mingw64-spice-protocol \
                curl

# Upgrade meson via pip to ensure >= 1.6.0 (required by QEMU HEAD for build.rust_std).
# The dnf package on Fedora may lag behind; pip ensures we get the latest.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 install --upgrade meson

# Set up ccache
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR="/ccache"

COPY angle/include/ /usr/x86_64-w64-mingw32/sys-root/mingw/include/
COPY angle/egl.pc /usr/x86_64-w64-mingw32/sys-root/mingw/lib/pkgconfig/
COPY angle/glesv2.pc /usr/x86_64-w64-mingw32/sys-root/mingw/lib/pkgconfig/
COPY WinHv*.h /usr/x86_64-w64-mingw32/sys-root/mingw/include/
COPY patches/ /patches/

RUN git clone https://github.com/anholt/libepoxy.git && \
    cd libepoxy && \
    mingw64-meson builddir -Dtests=false -Degl=yes -Dglx=no -Dx11=false && \
    ninja -C builddir -j4 && \
    ninja -C builddir install

# Stub sys/ioccom.h: virglrenderer's bundled drm-uapi/drm.h includes this
# BSD-only header unconditionally; it does not exist in the mingw sys-root.
# The stub provides the ioctl-encoding macros so the header compiles.
# The actual DRM ioctls are never called in the EGL/Windows build path.
RUN mkdir -p /usr/x86_64-w64-mingw32/sys-root/mingw/include/sys && \
    printf '%s\n' \
      '#pragma once' \
      '/* Stub sys/ioccom.h for cross-compilation to Windows */' \
      '#define IOC_VOID   0x20000000UL' \
      '#define IOC_OUT    0x40000000UL' \
      '#define IOC_IN     0x80000000UL' \
      '#define IOC_INOUT  (IOC_IN|IOC_OUT)' \
      '#define _IOC(d,g,n,l) ((d)|(((unsigned long)(l)&0x1fffUL)<<16UL)|((unsigned long)(g)<<8UL)|(unsigned long)(n))' \
      '#define _IO(g,n)     _IOC(IOC_VOID,(g),(n),0)' \
      '#define _IOR(g,n,t)  _IOC(IOC_OUT,(g),(n),sizeof(t))' \
      '#define _IOW(g,n,t)  _IOC(IOC_IN,(g),(n),sizeof(t))' \
      '#define _IOWR(g,n,t) _IOC(IOC_INOUT,(g),(n),sizeof(t))' \
    > /usr/x86_64-w64-mingw32/sys-root/mingw/include/sys/ioccom.h

# Build libslirp from source (no mingw64-libslirp package exists in Fedora repos)
RUN git clone https://gitlab.freedesktop.org/slirp/libslirp.git && \
    cd libslirp && \
    mingw64-meson build/ && \
    ninja -C build -j${BUILD_JOBS} && \
    ninja -C build install

# Build libspice-server (SPICE server required for guest clipboard agent channel)
RUN git clone https://gitlab.freedesktop.org/spice/spice.git && \
    cd spice && \
    mingw64-meson build/ \
        -Dclient=disabled \
        -Dgstreamer=no \
        -Dopus=enabled \
        -Dlz4=enabled && \
    ninja -C build -j${BUILD_JOBS} && \
    ninja -C build install

# Build virglrenderer from the main development branch
RUN mkdir -p /virglrenderer && \
    cd /virglrenderer && \
    curl -L https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/main/virglrenderer-main.tar.gz -o virglrenderer.tar.gz && \
    tar -xzf virglrenderer.tar.gz --strip-components=1 && \
    mingw64-meson build/ -Dplatforms=egl -Dminigbm_allocation=false && \
    ninja -C build -j${BUILD_JOBS} && \
    ninja -C build install

RUN --mount=type=cache,target=/root/.cargo/registry \
    git clone https://github.com/qemu/qemu.git && \
    cd qemu && \
    sed -i 's/SDL_SetHint(SDL_HINT_ANGLE_BACKEND, "d3d11");/#ifdef SDL_HINT_ANGLE_BACKEND\n            SDL_SetHint(SDL_HINT_ANGLE_BACKEND, "d3d11");\n#endif/' ui/sdl2.c && \
    sed -i 's/SDL_SetHint(SDL_HINT_ANGLE_FAST_PATH, "1");/#ifdef SDL_HINT_ANGLE_FAST_PATH\n            SDL_SetHint(SDL_HINT_ANGLE_FAST_PATH, "1");\n#endif/' ui/sdl2.c && \
    patch -p1 < /patches/qemu-10.1.2-sdl-clipboard.patch && \
    export NOCONFIGURE=1 && \
    export MESON=/usr/local/bin/meson && \
    ./configure --target-list=x86_64-softmmu \
    --prefix="${OUTPUT_DIR}" \
    --cross-prefix=x86_64-w64-mingw32- \
    --enable-whpx \
    --enable-virglrenderer \
    --enable-opengl \
    --enable-gtk \
    --enable-debug \
    --disable-stack-protector \
    --disable-werror \
    --disable-rust \
    --enable-sdl \
    --enable-sdl-image \
    --enable-slirp \
    --enable-spice && \
    make -j${BUILD_JOBS} && make install

# Add a step to copy the built binaries to the output directory
RUN mkdir -p ${OUTPUT_DIR}/bin && \
    cp -r ${OUTPUT_DIR}/*.exe ${OUTPUT_DIR}/bin/ || true && \
    cp -r ${OUTPUT_DIR}/x86_64-softmmu/*.exe ${OUTPUT_DIR}/bin/ || true && \
    cp /usr/x86_64-w64-mingw32/sys-root/mingw/bin/*.dll ${OUTPUT_DIR}/bin/ || true

# Create a script to copy files to the mounted volume
RUN echo '#!/bin/sh' > /copy-output.sh && \
    echo 'cp -r ${OUTPUT_DIR}/* /mnt/output/' >> /copy-output.sh && \
    echo 'echo "Build artifacts copied to output directory"' >> /copy-output.sh && \
    chmod +x /copy-output.sh

# Set the default command to copy outputs
CMD ["/copy-output.sh"]
