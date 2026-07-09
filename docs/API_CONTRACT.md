# 前后端接口草案

统一前缀：`/api`

## 通用响应

```json
{
  "data": {},
  "quality": {
    "source": "akshare",
    "from_cache": false,
    "updated_at": "2026-06-10T14:30:00Z",
    "stale": false,
    "warnings": []
  }
}
```

## 健康检查

### GET /api/health

响应：

```json
{
  "data": {
    "status": "ok",
    "version": "0.1.0"
  }
}
```

## 股票搜索

### GET /api/symbols/search

查询参数：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| q | string | 是 | 股票代码、名称或拼音 |
| limit | integer | 否 | 默认 20 |

响应：

```json
{
  "data": [
    {
      "symbol": "600519",
      "market": "SH",
      "name": "贵州茅台",
      "display": "600519.SH 贵州茅台"
    }
  ]
}
```

## 实时行情

### GET /api/quotes/realtime

查询参数：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| symbols | string | 是 | 逗号分隔，如 `600519,000001` |
| refresh | boolean | 否 | 是否强制刷新 |

响应：

```json
{
  "data": [
    {
      "symbol": "600519",
      "market": "SH",
      "name": "贵州茅台",
      "trade_time": "2026-06-10T14:30:00+08:00",
      "price": 1688.88,
      "open": 1680.0,
      "high": 1701.0,
      "low": 1670.0,
      "pre_close": 1675.0,
      "pct_chg": 0.83,
      "change": 13.88,
      "volume": 123456,
      "amount": 1234567890,
      "turnover": 0.42
    }
  ],
  "quality": {
    "source": "efinance",
    "from_cache": false,
    "updated_at": "2026-06-10T14:30:02Z",
    "stale": false,
    "warnings": []
  }
}
```

## K 线

### GET /api/kline/{symbol}

查询参数：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| period | string | 否 | `day` / `1m` / `5m` / `15m` / `30m` / `60m`，默认 `day` |
| start | string | 否 | `YYYY-MM-DD` |
| end | string | 否 | `YYYY-MM-DD` |
| adjust | string | 否 | `none` / `qfq` / `hfq`，默认 `qfq` |
| indicators | string | 否 | 逗号分隔，如 `ma,macd,rsi` |
| refresh | boolean | 否 | 是否强制刷新 |

响应：

```json
{
  "data": {
    "symbol": "600519",
    "period": "day",
    "adjust": "qfq",
    "bars": [
      {
        "time": "2026-06-10",
        "open": 1680.0,
        "high": 1701.0,
        "low": 1670.0,
        "close": 1688.88,
        "volume": 123456,
        "amount": 1234567890,
        "pct_chg": 0.83,
        "turnover": 0.42
      }
    ],
    "indicators": {
      "ma": {
        "ma5": [1681.2],
        "ma10": [1679.8],
        "ma20": [1660.4],
        "ma60": [1601.1]
      },
      "macd": {
        "dif": [1.2],
        "dea": [0.8],
        "hist": [0.8]
      },
      "rsi": {
        "rsi6": [55.3],
        "rsi12": [52.1],
        "rsi24": [49.8]
      }
    }
  },
  "quality": {
    "source": "akshare",
    "from_cache": true,
    "updated_at": "2026-06-10T12:00:00Z",
    "stale": false,
    "warnings": []
  }
}
```

## 资金流

### GET /api/money-flow/{symbol}

查询参数：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| period | string | 否 | `intraday` / `day`，默认 `day` |
| refresh | boolean | 否 | 是否强制刷新 |

响应：

```json
{
  "data": {
    "symbol": "600519",
    "items": [
      {
        "time": "2026-06-10",
        "main_net_inflow": 120000000,
        "super_large_net_inflow": 50000000,
        "large_net_inflow": 70000000,
        "medium_net_inflow": -20000000,
        "small_net_inflow": -100000000
      }
    ]
  },
  "quality": {
    "source": "efinance",
    "from_cache": false,
    "updated_at": "2026-06-10T14:30:00Z",
    "stale": false,
    "warnings": []
  }
}
```

## 自选股

### GET /api/watchlist

响应：

```json
{
  "data": [
    {
      "symbol": "600519",
      "market": "SH",
      "name": "贵州茅台",
      "group_name": "default",
      "sort_order": 1,
      "note": ""
    }
  ]
}
```

### POST /api/watchlist

请求：

```json
{
  "symbol": "600519",
  "group_name": "default",
  "note": ""
}
```

### DELETE /api/watchlist/{symbol}

删除自选股。

## 缓存管理

### POST /api/cache/refresh

请求：

```json
{
  "symbols": ["600519", "000001"],
  "data_types": ["quote", "kline_day", "money_flow"]
}
```

### DELETE /api/cache

查询参数：

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| data_type | string | 否 | 只清理某类缓存 |
| symbol | string | 否 | 只清理某只股票 |

