# Mac Fan Control

一个轻量的 macOS 菜单栏风扇控制工具：

- 读取当前风扇转速、最小/最大转速和手动/系统控制状态。
- 读取 SMC 暴露的 CPU、GPU 等温度传感器。
- 支持多条温度 -> 转速策略，达到不同温度段后切换到对应风扇转速。
- 支持设置低于某个温度时交还系统自动风扇控制。
- Apple Silicon 上通过特权 helper 执行风扇写入，读取仍由主 app 完成。

## 构建

```bash
./build.sh
```

构建产物位于：

```text
build/Mac Fan Control.app
```

## 运行

```bash
open "build/Mac Fan Control.app"
```

默认 `./build.sh` 使用 ad-hoc 签名。首次从 DMG 安装并启动时，应用会请求管理员授权，将风扇控制 helper 安装为仅允许当前 App 构建连接的系统 LaunchDaemon。

开发者也可以使用 Apple 代码签名身份构建，通过 `SMAppService` 安装 helper：

```bash
security find-identity -v -p codesigning
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./install.sh
```

`install.sh` 用于 Apple 签名的开发构建：它会重新生成 `.app`、替换 `/Applications/Mac Fan Control.app`，并强制重新注册本次构建内的风扇控制 helper。

## 传感器探测

```bash
"build/Mac Fan Control.app/Contents/MacOS/MacFanControl" --probe
```

## 风扇控制 helper

查看 helper 状态：

```bash
"/Applications/Mac Fan Control.app/Contents/MacOS/MacFanControl" --helper-status
```

重新触发注册：

```bash
"/Applications/Mac Fan Control.app/Contents/MacOS/MacFanControl" --install-helper
```

## 说明

不同 Mac 暴露的 SMC 键不同。当前实现优先读取 AppleSMC 的风扇键，例如 `FNum`、`F0Ac`、`F0Mn`、`F0Mx`、`F0Tg`。Apple Silicon 的 CPU/GPU 温度优先通过 IOHIDEventSystem 读取，例如 `PMU tdie*` 和 `PMU TP*g`。退出应用时会尝试恢复系统自动风扇控制。
