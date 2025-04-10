FROM fedora:latest

# Define build arguments and environment variables
ARG OUTPUT_DIR=/output
ENV OUTPUT_DIR=${OUTPUT_DIR}

# Set optimal number of build jobs based on available cores
ENV BUILD_JOBS=4

RUN dnf update -y && \
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
                diffutils

# Set up ccache
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR="/ccache"

COPY angle/include/ /usr/x86_64-w64-mingw32/sys-root/mingw/include/
COPY angle/egl.pc /usr/x86_64-w64-mingw32/sys-root/mingw/lib/pkgconfig/
COPY angle/glesv2.pc /usr/x86_64-w64-mingw32/sys-root/mingw/lib/pkgconfig/
COPY WinHv*.h /usr/x86_64-w64-mingw32/sys-root/mingw/include/

RUN git clone https://github.com/anholt/libepoxy.git && \
    cd libepoxy && \
    mingw64-meson builddir -Dtests=false -Degl=yes -Dglx=no -Dx11=false && \
    ninja -C builddir -j4 && \
    ninja -C builddir install

# Updated virglrenderer build using direct download of release tarball
RUN mkdir -p /virglrenderer && \
    cd /virglrenderer && \
    curl -L https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.1.1/virglrenderer-1.1.1.tar.gz -o virglrenderer.tar.gz && \
    tar -xzf virglrenderer.tar.gz --strip-components=1 && \
    mingw64-meson build/ -Dplatforms=egl -Dminigbm_allocation=false && \
    ninja -C build -j${BUILD_JOBS} && \
    ninja -C build install

RUN git clone https://github.com/qemu/qemu.git && \
    cd qemu && \
    sed -i 's/SDL_SetHint(SDL_HINT_ANGLE_BACKEND, "d3d11");/#ifdef SDL_HINT_ANGLE_BACKEND\n            SDL_SetHint(SDL_HINT_ANGLE_BACKEND, "d3d11");\n#endif/' ui/sdl2.c && \
    sed -i 's/SDL_SetHint(SDL_HINT_ANGLE_FAST_PATH, "1");/#ifdef SDL_HINT_ANGLE_FAST_PATH\n            SDL_SetHint(SDL_HINT_ANGLE_FAST_PATH, "1");\n#endif/' ui/sdl2.c && \
    export NOCONFIGURE=1 && \
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
    --enable-sdl && \
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
