# 构建与本机测试安装

本项目目前公开源码，没有完成通用安装包的发布验收。请先确认 [当前系统能力范围](validation.md)。构建成功、签名通过、后台获批和真实切换成功是不同的检查。

## 1. 只读开发包

需要 macOS、Python 3、Swift 工具链；可使用 Apple Command Line Tools。测试还需要工具链自带的 Swift Testing 框架。

```sh
python3 scripts/build_app.py
open build/LocaleShift.app
```

生成 `build/LocaleShift.app`，可体验配置管理、预览、双时钟与准备流程。默认 ad-hoc 签名，系统设置修改关闭。构建不注册服务，不修改系统设置。

为避免混淆菜单栏图标，请先从应用内正常退出已打开的副本。检查独立界面时可用：

```sh
open build/LocaleShift.app --args --data-directory "$PWD/.validation/ui-check" --show-management
```

自定义数据目录用于隔离界面检查，关闭真实系统修改和重启入口。

## 2. 无需完整 Xcode 的本机测试模式

该模式只用于自己机器上的功能测试，不能当作已完成正式签名与公证的发行版。系统兼容性限制仍然生效。

```sh
python3 scripts/build_app.py --local-development --output build/local-test/LocaleShift.app
python3 scripts/local_development.py install --app build/local-test/LocaleShift.app
```

第二步请求 macOS 管理员认证，密码只输入系统弹窗。安装器不修改三项系统设置，也不会自动注册后台服务。它将固定副本安装到 `/Library/Application Support/LocaleShiftLocalDevelopment/Builds/` 下，记录本机用户、构建标识和三个程序的代码哈希；工作目录副本保持只读。

安装成功后，从安装器打印的完整路径打开应用，然后：

1. 确认并保存完整系统默认配置。
2. 按引导手动关闭“使用你的当前位置自动设定时区”，网络校时保持原样。
3. 在应用预览页启用后台恢复；按 macOS 提示批准“系统设置 → 通用 → 登录项与扩展”中的后台服务。
4. 等待后台恢复可用，再应用目标设置并核对结果。
5. 完成后恢复系统默认，确认三项实际值与保存基准一致。

后台可能使用文件名“LocaleShift.app”显示。新构建具有新的标识，需要重新批准；注册状态不等于实际服务健康。应用不会自动检测自动时区开关。

### 更新与卸载

先在应用中恢复系统默认并正常退出，再执行：

```sh
python3 scripts/local_development.py remove
```

安装器会检查待恢复责任与服务状态，不满足删除条件时停止并保留程序和记录。用户记录会保留；新版重新构建、安装，不覆盖已注册的固定副本。

## 3. 使用自己的 Apple 签名身份

已有有效 macOS 开发／签名身份时：

```sh
python3 scripts/build_app.py --identity 'Apple Development: Your Name (TEAMID)' --require-system-switching --output build/signed/LocaleShift.app
```

脚本核验主应用、用户服务和特权服务的 Apple 锚、同一 Team ID 与预期标识。它不会注册服务或代表功能验收通过；系统版本门禁与后台批准仍然有效。

正式分发前还需要相应的分发签名、公证、安装／升级／卸载验收和兼容性验证。当前仓库不提供发布证书或私钥，也未提供可直接套用的正式分发流水线。

## 4. 检查构建

```sh
./scripts/test.sh
python3 scripts/build_app.py --configuration release --output build/check/LocaleShift.app
codesign --verify --deep --strict build/check/LocaleShift.app
```

只读诊断：

```sh
build/check/LocaleShift.app/Contents/MacOS/LocaleShift --diagnostics
build/check/LocaleShift.app/Contents/MacOS/LocaleShiftUserAgent --diagnostics
build/check/LocaleShift.app/Contents/MacOS/LocaleShiftTimezoneService --diagnostics
```

诊断可能包含本机路径及当前语言、地区和时区；提交 Issue 前检查并删去不想公开的内容。
