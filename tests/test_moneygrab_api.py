from fastapi.testclient import TestClient

import backend.app.main as main_module


class FakeScanner:
    def __init__(self):
        self.started_with = None
        self.state = {
            "status": "done",
            "total": 2,
            "done": 2,
            "hits": [
                {"symbol": "600001", "name": "命中股", "price": 13.1, "low90": 10.0, "pct": 31.0, "band": 20.0, "over": 1.0}
            ],
            "started_at": "2026-07-27T01:00:00+00:00",
            "finished_at": "2026-07-27T01:05:00+00:00",
            "error": None,
            "trade_date": "2026-07-27",
        }

    def start(self, refresh=False):
        self.started_with = refresh
        return {**self.state, "status": "running"}

    def status(self):
        return self.state


def make_client(monkeypatch) -> tuple[TestClient, FakeScanner]:
    fake = FakeScanner()
    monkeypatch.setattr(main_module, "get_scanner", lambda: fake)
    return TestClient(main_module.create_app()), fake


def test_start_scan(monkeypatch):
    client, fake = make_client(monkeypatch)
    response = client.post("/api/moneygrab/scan?refresh=true")
    assert response.status_code == 200
    assert response.json()["data"]["status"] == "running"
    assert fake.started_with is True


def test_scan_status(monkeypatch):
    client, _ = make_client(monkeypatch)
    response = client.get("/api/moneygrab/scan/status")
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["status"] == "done"
    assert data["hits"][0]["symbol"] == "600001"
