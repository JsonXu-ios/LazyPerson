from __future__ import annotations

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from backend.app.cache import CacheStore
from backend.app.config import Settings, get_settings
from backend.app.errors import ProviderError
from backend.app.models import ApiResponse, DataQuality, WatchlistCreate
from backend.app.scanner import get_scanner, get_zero_base_scanner
from backend.app.services import MarketService


def provider_http_error(exc: ProviderError) -> HTTPException:
    return HTTPException(
        status_code=503,
        detail={
            "message": "数据源暂时不可用，可稍后刷新或查看已有缓存。",
            "reason": str(exc),
        },
    )


def get_cache(settings: Settings = Depends(get_settings)) -> CacheStore:
    return CacheStore(settings)


def get_market_service(
    settings: Settings = Depends(get_settings),
    cache: CacheStore = Depends(get_cache),
) -> MarketService:
    return MarketService(settings, cache)


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title=settings.app_name, version=settings.app_version)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.get("/api/health", response_model=ApiResponse)
    def health() -> ApiResponse:
        return ApiResponse(data={"status": "ok", "version": settings.app_version})

    @app.get("/api/symbols/search", response_model=ApiResponse)
    def search_symbols(
        q: str,
        limit: int = Query(default=20, ge=1, le=100),
        refresh: bool = False,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        try:
            data, quality = service.search_symbols(q, limit=limit, refresh=refresh)
            return ApiResponse(data=data, quality=quality)
        except ProviderError as exc:
            raise provider_http_error(exc) from exc

    @app.get("/api/quotes/realtime", response_model=ApiResponse)
    def realtime_quotes(
        symbols: str,
        refresh: bool = False,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        try:
            data, quality = service.realtime_quotes(symbols.split(","), refresh=refresh)
            return ApiResponse(data=data, quality=quality)
        except ProviderError as exc:
            raise provider_http_error(exc) from exc

    @app.get("/api/kline/{symbol}", response_model=ApiResponse)
    def kline(
        symbol: str,
        period: str = "day",
        start: str | None = None,
        end: str | None = None,
        adjust: str | None = None,
        indicators: str = "",
        limit: int | None = Query(default=None, ge=1, le=5000),
        refresh: bool = False,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        effective_limit = limit
        if effective_limit is None:
            effective_limit = 140 if period in ("day", "week", "month") else 1000
        try:
            data, quality = service.kline(
                symbol=symbol,
                period=period,
                start=start,
                end=end,
                adjust=adjust,
                indicators=[item for item in indicators.split(",") if item],
                limit=effective_limit,
                refresh=refresh,
            )
            return ApiResponse(data=data, quality=quality)
        except ProviderError as exc:
            raise provider_http_error(exc) from exc

    @app.get("/api/money-flow/{symbol}", response_model=ApiResponse)
    def money_flow(
        symbol: str,
        period: str = "day",
        refresh: bool = False,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        try:
            data, quality = service.money_flow(symbol, period=period, refresh=refresh)
            return ApiResponse(data=data, quality=quality)
        except ProviderError as exc:
            raise provider_http_error(exc) from exc

    @app.get("/api/fundamentals/{symbol}", response_model=ApiResponse)
    def fundamentals(
        symbol: str,
        refresh: bool = False,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        try:
            data, quality = service.fundamentals(symbol, refresh=refresh)
            return ApiResponse(data=data, quality=quality)
        except ProviderError as exc:
            raise provider_http_error(exc) from exc

    @app.get("/api/watchlist", response_model=ApiResponse)
    def list_watchlist(
        group_name: str | None = None,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        return ApiResponse(data=service.list_watchlist(group_name))

    @app.post("/api/watchlist", response_model=ApiResponse)
    def add_watchlist(
        payload: WatchlistCreate,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        service.add_watchlist(payload.symbol, payload.group_name, payload.note)
        return ApiResponse(data={"ok": True})

    @app.delete("/api/watchlist/{symbol}", response_model=ApiResponse)
    def remove_watchlist(
        symbol: str,
        group_name: str | None = None,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        service.remove_watchlist(symbol, group_name)
        return ApiResponse(data={"ok": True})

    @app.get("/api/popularity", response_model=ApiResponse)
    def popularity(
        limit: int = Query(default=100, ge=1, le=100),
        refresh: bool = False,
        cache: CacheStore = Depends(get_cache),
    ) -> ApiResponse:
        from backend.app.popularity import PopularityService

        rows, warnings = PopularityService(cache).hot_stocks(limit=limit, refresh=refresh)
        return ApiResponse(data=rows, quality=DataQuality(source="eastmoney", warnings=warnings))

    @app.get("/api/sectors/hot", response_model=ApiResponse)
    def hot_sectors(
        limit: int = Query(default=20, ge=1, le=60),
        refresh: bool = False,
        cache: CacheStore = Depends(get_cache),
    ) -> ApiResponse:
        from backend.app.sectors import SectorService

        data, warnings = SectorService(cache).hot_boards(limit=limit, refresh=refresh)
        return ApiResponse(data=data, quality=DataQuality(source="mixed", warnings=warnings))

    @app.get("/api/sectors/{code}/constituents", response_model=ApiResponse)
    def sector_constituents(
        code: str,
        limit: int = Query(default=60, ge=1, le=200),
        refresh: bool = False,
        cache: CacheStore = Depends(get_cache),
    ) -> ApiResponse:
        from backend.app.sectors import SectorService

        rows, warnings = SectorService(cache).constituents(code, limit=limit, refresh=refresh)
        return ApiResponse(data=rows, quality=DataQuality(source="eastmoney", warnings=warnings))

    @app.get("/api/stock/{symbol}/industry", response_model=ApiResponse)
    def stock_industry(
        symbol: str,
        refresh: bool = False,
        cache: CacheStore = Depends(get_cache),
    ) -> ApiResponse:
        from backend.app.industry import IndustryService

        data, warnings = IndustryService(cache).industry_of(symbol, refresh=refresh)
        return ApiResponse(data=data, quality=DataQuality(source="baostock", warnings=warnings))

    @app.post("/api/moneygrab/scan", response_model=ApiResponse)
    def start_moneygrab_scan(
        refresh: bool = False,
        min_market_cap: float | None = Query(default=None, ge=0, description="总市值下限，亿元"),
        limit_up: bool = Query(default=False, description="只要最后一天（今日）涨停的"),
    ) -> ApiResponse:
        return ApiResponse(
            data=get_scanner().start(refresh=refresh, min_market_cap=min_market_cap, limit_up_only=limit_up)
        )

    @app.get("/api/moneygrab/scan/status", response_model=ApiResponse)
    def moneygrab_scan_status() -> ApiResponse:
        return ApiResponse(data=get_scanner().status())

    @app.post("/api/zero-base/scan", response_model=ApiResponse)
    def start_zero_base_scan(refresh: bool = False) -> ApiResponse:
        """零帧起手：独立于八档局的一次全市场扫描（不套市值/涨停参数）。"""
        return ApiResponse(data=get_zero_base_scanner().start(refresh=refresh))

    @app.post("/api/zero-base/enrich", response_model=ApiResponse)
    def enrich_zero_base() -> ApiResponse:
        """只补基本面标记（分红/净利润/估市值），不重扫。"""
        return ApiResponse(data=get_zero_base_scanner().enrich())

    @app.get("/api/zero-base/scan/status", response_model=ApiResponse)
    def zero_base_scan_status() -> ApiResponse:
        return ApiResponse(data=get_zero_base_scanner().status())

    @app.post("/api/cache/refresh", response_model=ApiResponse)
    def refresh_cache() -> ApiResponse:
        return ApiResponse(data={"ok": True, "message": "Use refresh=true on data APIs for targeted refresh."})

    @app.delete("/api/cache", response_model=ApiResponse)
    def clear_cache(
        data_type: str | None = None,
        symbol: str | None = None,
        service: MarketService = Depends(get_market_service),
    ) -> ApiResponse:
        count = service.clear_cache(data_type=data_type, symbol=symbol)
        return ApiResponse(data={"cleared": count})

    return app


app = create_app()
