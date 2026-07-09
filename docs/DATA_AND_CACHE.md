# 数据源与缓存策略

## 数据源分工

| 数据类型 | 首选 | 备选 | 说明 |
| --- | --- | --- | --- |
| 实时行情 | efinance | AKShare | 优先速度和字段完整度 |
| 分钟 K 线 | efinance / 东方财富 | AKShare | 日内走势优先走东方财富链路 |
| 历史日 K | AKShare | BaoStock / efinance | 日线稳定性优先 |
| 股票列表 | AKShare | efinance | 用于搜索和名称映射 |
| 资金流 | efinance / AKShare | 无 | 字段差异较大，需标准化 |
| 复权数据 | AKShare | BaoStock | 日线分析默认前复权可配置 |

## Provider 路由规则

建议用显式规则，不做过早智能调度：

```text
quote.realtime -> efinance -> AKShare -> cache
kline.minute  -> efinance -> AKShare -> cache
kline.day     -> AKShare -> BaoStock -> efinance -> cache
money_flow    -> efinance -> AKShare -> cache
symbols       -> AKShare -> efinance -> cache
```

每次响应都带上数据质量：

```json
{
  "source": "efinance",
  "from_cache": false,
  "updated_at": "2026-06-10T14:30:00Z",
  "stale": false,
  "warnings": []
}
```

## 本地缓存目录

```text
data/
  cache/
    lazy_person.sqlite
    kline/
      day/
        600519.parquet
      minute/
        1m/
          600519.parquet
        5m/
          600519.parquet
    quote/
      realtime.parquet
    money_flow/
      600519.parquet
```

## SQLite 表设计

### symbols

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| symbol | text | 股票代码 |
| market | text | 交易所，`SH` / `SZ` / `BJ` |
| name | text | 名称 |
| pinyin | text | 拼音搜索 |
| listed_at | text | 上市日期 |
| updated_at | text | 更新时间 |

### watchlist

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| id | integer | 主键 |
| symbol | text | 股票代码 |
| group_name | text | 分组 |
| sort_order | integer | 排序 |
| note | text | 备注 |
| created_at | text | 创建时间 |

### cache_index

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| cache_key | text | 缓存键 |
| data_type | text | `quote` / `kline_day` / `kline_minute` / `money_flow` |
| symbol | text | 股票代码 |
| period | text | 周期 |
| path | text | Parquet 路径 |
| source | text | 数据源 |
| start_at | text | 数据开始时间 |
| end_at | text | 数据结束时间 |
| updated_at | text | 缓存更新时间 |
| ttl_seconds | integer | TTL |

## TTL 建议

| 数据 | 交易时间 TTL | 非交易时间 TTL |
| --- | --- | --- |
| 实时行情 | 5 秒 | 5 分钟 |
| 1 分钟 K | 30 秒 | 10 分钟 |
| 5/15/30/60 分钟 K | 60 秒 | 10 分钟 |
| 日 K | 30 分钟 | 12 小时 |
| 股票列表 | 24 小时 | 24 小时 |
| 资金流 | 60 秒 | 30 分钟 |

## 增量更新策略

### 日 K

1. 读取本地 Parquet 的最大交易日。
2. 如果本地为空，按默认起始日全量拉取。
3. 如果本地存在，从最大交易日往前回看 3 个交易日重新拉取。
4. 合并后按 `trade_date` 去重，以最新数据源结果为准。

回看 3 个交易日是为了处理复权、停牌、数据源延迟修正等情况。

### 分钟 K

1. 交易时间内按周期 TTL 刷新。
2. 每次拉取覆盖当日数据。
3. 历史分钟数据如果数据源支持，可按日期分区；否则只保留近期窗口。

### 实时行情

实时行情适合批量拉取自选股，避免每只股票单独请求。

建议缓存键：

```text
quote:realtime:watchlist:{group_name}
```

## 字段标准化

第三方库可能返回中文列名或不同单位，进入缓存前必须统一：

| 标准字段 | 说明 |
| --- | --- |
| trade_time | 时间戳，统一 ISO 或 UTC |
| open/high/low/close | 价格，float |
| volume | 成交量，保留原始股/手单位并在 metadata 记录 |
| amount | 成交额，人民币 |
| pct_chg | 涨跌幅，百分比 |
| turnover | 换手率，百分比 |
| adjust | `none` / `qfq` / `hfq` |

## 数据质量规则

返回给前端的数据要能解释“为什么看起来不对”：

- `stale=true`：缓存已过期，但远端失败，返回旧数据。
- `warnings=["provider_timeout"]`：数据源超时。
- `warnings=["partial_data"]`：只拿到部分区间。
- `warnings=["field_missing:turnover"]`：缺字段。

## 注意事项

- efinance 文档声明项目主要用于学习交流，并提示网络或限流问题时可能需要替代数据源。实现中要把限流、超时、字段缺失当成常态处理。
- AKShare 数据范围广，接口数量多，但接口字段和名称可能随版本更新，adapter 层必须集中做兼容。
- BaoStock 需要登录会话，适合作为历史补齐和校验来源，不建议放在实时链路上。

