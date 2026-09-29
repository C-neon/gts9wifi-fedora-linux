#!/bin/bash
# SPDX-License-Identifier: MIT
# 本地极速内核编译 & 发布脚本 (运行于宿主机 WSL2)
# 产物自动推送到 GitHub Pre-release (experimental 滚动测试标签)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KVER="7.2.0-gts9wifi"
RELEASE_TAG="${1:-experimental}"

echo "=========================================================="
echo " GTS9WIFI 本地高速内核编译构建系统"
echo " 目标版本: $KVER"
echo " 发布标签: $RELEASE_TAG (Pre-release)"
echo " 并行线程: $(nproc) 线程"
echo "=========================================================="

cd "$REPO_DIR"

# 1. 确保最新代码
echo "--> 1. 检查并拉取最新代码..."
git pull origin main || true

# 2. 缓存与依赖源码准备
CACHE_DIR="/home/neon/.cache/gts9wifi-kernel"
mkdir -p "$CACHE_DIR"

if [ ! -f "$CACHE_DIR/linux-7.2.tar.gz" ]; then
    echo "--> 2. 下载上游 Linux 7.2 基础源码包..."
    curl -sfL https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.gz -o "$CACHE_DIR/linux-7.2.tar.gz"
fi

FIRMWARE_URL="https://github.com/nacht20-de/gts9wifi-fedora/releases/download/kernel-7.2.0-rc3-gts9wifi-2/firmware-samsung-gts9wifi-v2.tar.gz"
FIRMWARE_SHA256="30cace40556fdaf1577c76bedc1b1a6236f4acc23e9300253b3834fa7ed4bab5"

if [ ! -f "$CACHE_DIR/fw.tar.gz" ]; then
    echo "--> 下载配套 GPU/ADSP 固件包..."
    curl -sfL "$FIRMWARE_URL" -o "$CACHE_DIR/fw.tar.gz"
    echo "$FIRMWARE_SHA256  $CACHE_DIR/fw.tar.gz" | sha256sum -c -
fi

# 3. 准备打补丁源码树
BUILD_TREE="/home/neon/kbuild/linux-7.2"
echo "--> 3. 准备源码并打入 SM-X710 专属补丁..."
if [ ! -d "$BUILD_TREE" ]; then
    rm -rf /home/neon/kbuild
    mkdir -p /home/neon/kbuild
    tar xf "$CACHE_DIR/linux-7.2.tar.gz" -C /home/neon/kbuild
    cd "$BUILD_TREE"
    bash "$REPO_DIR/kernel/prepare.sh" .
    echo "-gts9wifi" > localversion-gts9wifi
else
    cd "$BUILD_TREE"
    cp -a "$REPO_DIR/kernel/files/"* drivers/input/keyboard/ 2>/dev/null || true
    cp "$REPO_DIR/kernel/files/samsung_stm32_pogo.c" drivers/input/keyboard/ 2>/dev/null || true
    cp "$REPO_DIR/kernel/files/sm8550-samsung-gts9wifi.dts" arch/arm64/boot/dts/qcom/ 2>/dev/null || true
fi

# 4. 交叉编译内核与设备树
echo "--> 4. 开始全核并行极速编译..."
export ARCH=arm64

make -j$(nproc) ARCH=arm64 LLVM=1 vmlinuz.efi dtbs modules

# 5. 生成 initramfs
echo "--> 5. 构建 initramfs (集成 GPU 固件与 USB-Net)..."
STAGE_DIR="/home/neon/stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/boot" "$STAGE_DIR/usr/lib/modules" "$STAGE_DIR/out-bundle" "$STAGE_DIR/out-twrp"

# 安装模块到临时目录
make -j$(nproc) ARCH=arm64 LLVM=1 modules_install INSTALL_MOD_PATH="$STAGE_DIR/usr" INSTALL_MOD_STRIP=1
cp arch/arm64/boot/vmlinuz.efi "$STAGE_DIR/boot/vmlinuz-$KVER"
mkdir -p "$STAGE_DIR/boot/dtbs-$KVER/qcom"
cp arch/arm64/boot/dts/qcom/sm8550-samsung-gts9wifi.dtb "$STAGE_DIR/boot/dtbs-$KVER/qcom/"

# 临时解压 GPU 固件以供 dracut 抓取
if [ ! -f /usr/lib/firmware/qcom/a740_sqe.fw ]; then
    echo "--> 安装 GPU 固件至系统..."
    sudo mkdir -p /usr/lib/firmware
    sudo tar xzf "$CACHE_DIR/fw.tar.gz" -C /
fi

mkdir -p /home/neon/.local/share/dracut/modules.d
cp -a "$REPO_DIR/boot/dracut/90gts9wifi-usbnet" /home/neon/.local/share/dracut/modules.d/ 2>/dev/null || true

dracut --kver "$KVER" --kmoddir "$STAGE_DIR/usr/lib/modules/$KVER" \
    --include "$REPO_DIR/boot/dracut/90gts9wifi-usbnet" /usr/lib/dracut/modules.d/90gts9wifi-usbnet \
    --conf "$REPO_DIR/boot/dracut/dracut.conf.d/gts9wifi.conf" \
    --force "$STAGE_DIR/boot/initramfs.img"

# 6. 生成 Android 启动镜像 Bundle 与 TWRP ZIP
echo "--> 6. 生成 Android V4 引导 Bundle 与 TWRP 刷机 ZIP..."
bash "$REPO_DIR/boot/build-bundle.sh" \
    --vmlinuz "$STAGE_DIR/boot/vmlinuz-$KVER" \
    --dtb "$STAGE_DIR/boot/dtbs-$KVER/qcom/sm8550-samsung-gts9wifi.dtb" \
    --initramfs "$STAGE_DIR/boot/initramfs.img" \
    --cmdline "$REPO_DIR/boot/cmdline.txt" \
    --bootconfig "$REPO_DIR/boot/bootconfig.txt" \
    --out "$STAGE_DIR/out-bundle"

python3 "$REPO_DIR/tools/make-twrp-zip.py" "$STAGE_DIR/out-bundle" \
    "$STAGE_DIR/out-twrp/gts9wifi-fedora-$KVER.zip" --project "$REPO_DIR"

# 7. 打包内核 RPM 安装包 (提供完整的 /usr/lib/modules 内核模块与符号)
echo "--> 7. 构建 aarch64 内核 RPM 安装包..."
mkdir -p /home/neon/rpmbuild/BUILDROOT/linux-gts9wifi-7.2.0-0.1.fc44.aarch64/boot
mkdir -p /home/neon/rpmbuild/BUILDROOT/linux-gts9wifi-7.2.0-0.1.fc44.aarch64/usr/lib/modules
mkdir -p /home/neon/rpmbuild/SPECS "$STAGE_DIR/out-kernel"

cp -a "$STAGE_DIR/boot"/* /home/neon/rpmbuild/BUILDROOT/linux-gts9wifi-7.2.0-0.1.fc44.aarch64/boot/
cp -a "$STAGE_DIR/usr/lib/modules/7.2.0-gts9wifi" /home/neon/rpmbuild/BUILDROOT/linux-gts9wifi-7.2.0-0.1.fc44.aarch64/usr/lib/modules/
touch /home/neon/rpmbuild/BUILDROOT/linux-gts9wifi-7.2.0-0.1.fc44.aarch64/COPYING

cat << 'EOF' > /home/neon/rpmbuild/SPECS/linux-gts9wifi.spec
%define debug_package %{nil}
%define _build_id_links none
Name:           linux-gts9wifi
Version:        7.2.0
Release:        0.1.fc44
Summary:        Mainline Linux kernel for Samsung Galaxy Tab S9 Wi-Fi (gts9wifi)
License:        GPL-2.0-only
BuildArch:      aarch64
Provides:       kernel-uname-r
AutoReqProv:    no

%description
Mainline 7.2.0 kernel and module tree for Samsung Galaxy Tab S9 Wi-Fi.

%files
%license COPYING
/boot/*
/usr/lib/modules/*
EOF

rpmbuild -bb --target aarch64 --buildroot /home/neon/rpmbuild/BUILDROOT/linux-gts9wifi-7.2.0-0.1.fc44.aarch64 /home/neon/rpmbuild/SPECS/linux-gts9wifi.spec
cp /home/neon/rpmbuild/RPMS/aarch64/*.rpm "$STAGE_DIR/out-kernel/"

# 8. 上传至 GitHub Pre-release (滚动覆盖)
echo "--> 8. 推送产物直达 GitHub Pre-release ($RELEASE_TAG)..."
cd "$REPO_DIR"
mv "$STAGE_DIR/out-bundle/SHA256SUMS" "$STAGE_DIR/out-bundle/BUNDLE-SHA256SUMS" || true

RELEASE_NOTES="⚠️ Experimental testing build for Samsung Galaxy Tab S9 (SM-X710).
- Pogo STM32 V37 firmware auto-flash
- Display KEY_WAKEUP lid event support
- Global suspend disabled for watchdog stability

This is a rolling test build and may be updated or replaced without notice."

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    gh release edit "$RELEASE_TAG" --title "Experimental Test Build ($RELEASE_TAG)" --notes "$RELEASE_NOTES" --prerelease --latest=false
else
    gh release create "$RELEASE_TAG" --title "Experimental Test Build ($RELEASE_TAG)" --notes "$RELEASE_NOTES" --prerelease --latest=false
fi

gh release upload "$RELEASE_TAG" --clobber \
    "$STAGE_DIR"/out-kernel/*.rpm \
    "$STAGE_DIR"/out-bundle/*.img "$STAGE_DIR"/out-bundle/BUNDLE-SHA256SUMS "$STAGE_DIR"/out-bundle/BUILD-METADATA.txt \
    "$STAGE_DIR"/out-twrp/*.zip

echo "=========================================================="
echo " 编译与发布完成！"
echo " Pre-release 页面: https://github.com/C-neon/gts9wifi-fedora-linux/releases/tag/$RELEASE_TAG"
echo "=========================================================="
