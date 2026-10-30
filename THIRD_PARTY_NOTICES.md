# 第三方数据与资源说明

项目代码按根目录 [MIT 许可证](LICENSE) 提供；第三方数据保持原有声明。

## IANA 时区数据

`Sources/LocaleShiftCore/Resources/zone.tab` 来自 IANA 时区数据库，原文件保留 public domain 声明。随包版本由 `tzdb-version.txt` 记录。时区链接映射位于 `timezone-links.json`，实际时区规则与夏令时计算使用系统 Foundation。

参考：[IANA Time Zone Database](https://www.iana.org/time-zones)、[数据库与许可说明](https://data.iana.org/time-zones/tz-link.html)。

## 地点与首都映射

`timezone-places.json` 和 `capital-timezones.json` 是项目人工整理的数据，维护来源及限制见 [地点数据说明](docs/data/timezone-places.md) 和 [首都时区说明](docs/data/capital-timezones.md)。这些文件不是所列机构发布的完整数据集。

中文标准城市名称在运行时通过系统 Foundation／CLDR 能力获取，项目未打包完整 Unicode CLDR 数据库。

## 图标

当前应用与菜单栏图标由本项目设计迭代，使用 AI 图像生成工具制作。仓库保留当前构建所需原稿及生成资源；转换脚本为 `scripts/prepare_branding.sh`。

## 系统组件

SQLite 通过 macOS 系统库链接；AppKit、SwiftUI、Foundation、Security、ServiceManagement 等由 Apple SDK／系统提供。本项目没有第三方 Swift Package 网络依赖。
