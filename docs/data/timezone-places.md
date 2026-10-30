# 中文城市与州名查找

维护日期：2026-10-13。首版美国数据来自人工整理的50州及哥伦比亚特区对应关系，存于 `timezone-places.json`；候选标识与随包 IANA `zone.tab` 一致。跨时区州按区域分条，不用当前偏移相等推断任意地点可互换。州边界或当地规则变化时须更新数据，不能仅改显示名称。

- 中文城市：Foundation DateFormatter 使用 Unicode CLDR 的 `VVV`（exemplar city）模式；原有常用中文城市名保留。系统未提供译名时才回退标准地点名，不用共享的“北美东部时间”替代不同城市名。
- 地点查找：支持州的中文／英文名、州代码、部分常用城市别名。完整精确名称优先；例如 `VA`、`Virginia`、`弗吉尼亚`、`佛吉尼亚` 返回美国候选 `America/New_York`。
- 区域区分：Florida、Texas、Arizona等州保留不同地区结果；`Arlington` 同时列出弗吉尼亚和得克萨斯对应区域，`Washington` 同时列出州和首都，不能自动假定唯一地点。
- 城市别名未承诺完整世界地名覆盖。其他国家基础能力为系统中文标准城市、英文时区代表地点和时区名称搜索。
- UI使用限高内联列表，唯一结果可回车选择，鼠标按钮与回车共用同一选择方法。州名不新增系统时区，也不成为配置唯一性字段；不自动保存IP或检测网络出口。

维护参考：

- [Unicode CLDR 城市与时区名称](https://cldr.unicode.org/translation/time-zones-and-city-names)
- [Unicode LDML 日期格式 VVV 定义](https://unicode.org/reports/tr35/tr35-dates.html)
- [IANA 时区数据库](https://www.iana.org/time-zones)及随包2026d的`zone.tab`区域说明
- [美国NIST时区图](https://nist.time.gov/)：当前时区总体范围；维护跨区州时还须核对具体县市。
- [弗吉尼亚州官方门户的东部时间说明](https://grants.dss.virginia.gov/)

这里列出的是数据维护参考，不表示官方发布了本项目的完整JSON。应用没有州边界地理编码服务，用户只知道跨时区州时需根据结果中的具体区域继续确认。
