# 首都／行政中心时区推荐数据

维护日期：2026-10-13。数据位于 `Sources/LocaleShiftCore/Resources/capital-timezones.json`，与应用打包，无需联网。45项人工整理的首都／行政中心映射，覆盖28个有明确映射的多时区地区及17个常用单时区地区。

这份映射是新建时的推荐依据，不是国家首都的完整名录，也不参与已保存配置的迁移。IANA 以代表性地点标识时区，不要求每个首都有独立标识：例如华盛顿使用 America/New_York、堪培拉使用 Australia/Sydney、渥太华使用 America/Toronto。UI 同时显示推荐地点和标准代表城市，不创建虚构的 America/Washington 或 Australia/Canberra 标识。

校验规则：每条映射必须属于对应地区随包 zone.tab 的候选，并为当前 Foundation TimeZone 接受。失效条目不推荐；无条目的单时区地区自动选择唯一时区，多时区地区明确提示手动选择。南极洲、美国本土外小岛屿以及本轮未收录可靠映射的巴勒斯坦地区保留手动选择，不把列表第一项当作首都。

地名说明：GL、PF 等使用行政中心；瑞士使用伯尔尼行政中心，南非默认行政首都比勒陀利亚。印尼本版按雅加达，后续如正式迁都须更新映射，不能只更换名称而保留旧时区。时区规则和夏令时由 IANA 标识交给系统处理，不在此文件固定 UTC 偏移。

来源与维护参考：

- [IANA 时区命名原则](https://www.iana.org/time-zones/theory)：首都不一定有独立的时区名称。
- 随包 `zone.tab` 与 `tzdb-version.txt`（当前 2026d）：地区候选及标准标识。
- [美国 NIST 官方时钟](https://nist.time.gov/)与[当地时间说明](https://www.nist.gov/pml/time-and-frequency-division/local-time-faqs)：美国时区和夏令时。
- [加拿大国家研究委员会的渥太华计时说明](https://www.nrc.canada.ca/en/research-development/research-collaboration/behind-scenes-look-work-canadas-timekeepers)：渥太华东部时间。
- [澳大利亚新南威尔士州时间规定](https://dcj.nsw.gov.au/about-us/daylight-saving/definitions-of-time-and-how-time-is-regulated.html)：ACT 与 NSW 时间规则。
- [巴西官方报时服务](https://www.gov.br/pt-br/servicos/hora-falada-on)：巴西利亚时间。
- [印尼宪法法院2026年迁都说明](https://www.mkri.id/berita/waktu-pemindahan-ikn-bergantung-pada-pemberlakuan-keputusan-presiden-25031)：迁都生效取决于总统决定。

这些链接是规则与关键映射的维护参考，不表示它们发布了本项目完整的45项 JSON。新条目须核对地点与时区，更新产品文档、现有推荐回归和数据校验；不可用当前 UTC 偏移相等替代时区对应关系。
