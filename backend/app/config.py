from functools import lru_cache
import os
from pathlib import Path

from dotenv import load_dotenv


load_dotenv()


class Settings:
    app_name: str = os.getenv("APP_NAME", "LazyPerson")
    app_version: str = os.getenv("APP_VERSION", "0.1.0")
    cache_dir: Path = Path(os.getenv("CACHE_DIR", "data/cache"))
    default_adjust: str = os.getenv("DEFAULT_ADJUST", "qfq")
    quote_ttl_seconds: int = int(os.getenv("QUOTE_TTL_SECONDS", "5"))
    minute_ttl_seconds: int = int(os.getenv("MINUTE_TTL_SECONDS", "30"))
    day_ttl_seconds: int = int(os.getenv("DAY_TTL_SECONDS", "1800"))
    symbols_ttl_seconds: int = int(os.getenv("SYMBOLS_TTL_SECONDS", "86400"))
    money_flow_ttl_seconds: int = int(os.getenv("MONEY_FLOW_TTL_SECONDS", "60"))
    cors_origins: list[str] = [
        item.strip()
        for item in os.getenv(
            "CORS_ORIGINS",
            "http://localhost:5175,http://127.0.0.1:5175",
        ).split(",")
        if item.strip()
    ]

    @property
    def sqlite_path(self) -> Path:
        return self.cache_dir / "lazy_person.sqlite"


@lru_cache
def get_settings() -> Settings:
    return Settings()
