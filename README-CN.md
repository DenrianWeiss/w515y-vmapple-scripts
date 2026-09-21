# macOS (vmapple) + Reims vGPU 在 aarch64 Linux/KVM 上的源代码包

该源代码包用于在华为 w515y 上构建和启动带有 Reims vGPU 的 Apple `vmapple` 机器模拟，目前测试过运行 macOS 13 系统。
你需要 16GB 内存的配置，8GB的配置启动就会带死系统。另外，本项目只作为研究用途，如果你想使用 macOS，请购买一台 mac （而且大概会比 w515y 便宜点）

本仓库及相关内容禁止转载到小红书、咸鱼或用于商业用途。

## 感谢

本项目基于 [imbushuo 的工作](https://github.com/imbushuo)，以及 steelhead 的 QEMU 和 reims-vGPU 的 fork。同时，我们参考了 Asahi Linux 在 Linux 上支持 Apple Silicon 的努力，特别是苹果厂商特定寄存器的资料。

## 需要准备的内容

- 买或借来的一台 Apple Silicon Mac 设备，用于创建初始镜像包、生成必要的固件文件。
- macOS 13 的 ipsw，请合法从苹果获取。
- 16G 内存的 w515y 主机
- 麒麟或 UOS 系统
- 良好的 GitHub 连接

## 备注

- 由于缺少硬件特性，高通平台无法运行苹果的 XNU 内核，任何声称可以运行的说法都是错误的。

## 构建步骤

首先去 `https://rustup.rs` 安装 `cargo` 和 `rustup`，之后通过系统包管理器安装如下包：

```sh
sudo apt install build-essential ninja-build pkg-config git gdb clang python3 \
     python3-venv python3-pip zlib1g-dev libpixman-1-dev libslirp-dev \
     libglib2.0-dev libnettle-dev libxkbcommon-dev libwayland-dev \
     libx11-dev libxrandr-dev libxi-dev libxcursor-dev libvulkan-dev \
     vulkan-tools libgtk-3-dev linux-headers-$(uname -r)
```

然后你需要编译 llvm 22，并确保生成的 `libLLVM.so.22` 可用。
另外，你需要获取 python 3.12 或更高的版本。
如果你使用 UOS，你需要自行构建高版本的 GCC/Clang 和 Python，UOS 自带的版本过旧会出错。

之后，克隆本仓库，并执行

```sh
./build.sh                 # deps check + clone + patch + configure + ninja + verify
RECLONE=1 ./build.sh       # start over from an empty src/ and kmod/
JOBS=8 ./build.sh
KMOD_CHECK=1 ./build.sh    # also compile-check the kernel modules
```

## 启动

你需要把 mac 上准备的相应文件复制到本文件夹下的 images 目录中。

```sh
BOOTER=/images/AVPBooter.vmapple2.bin \
AUX=/images/aux.img \
DISK=/images/disk.img \
METAL2VULKAN_LLVM_LIBRARY=libLLVM.so.22 \
./launch/launch-macos-gui.sh
```

### 获取相应文件的方法

在你买来或者借来的 mac 上克隆 https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64 这个仓库，之后去 https://github.com/s-u/macosvm 下载 release 里的二进制文件，然后把该文件加到 path 里，之后去克隆的仓库里执行:

```sh
IPSW=/path/to/UniversalMac_13.6_22G120_Restore.ipsw \
  scripts/provision-on-macos.sh
```

即可获取 aux 及 disk.img

AVPBooter.vmapple2.bin 可以从你的 mac 设备或 IPSW 中提取，它位于：`/System/Library/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin`，推荐使用 macOS 26.5 以上版本的系统。

确保将提取的文件放置在本仓库的 `images` 目录下，以便启动脚本能够正确找到它们。

## 备注

如果你看不懂，那你把这个文档丢给你的电子牛马看看吧。另外这个仓库是从脏工作环境 checkout 出来的，不能保证完全可用。