class ProviderError(RuntimeError):
    def __init__(self, message: str, source: str = "unknown"):
        super().__init__(message)
        self.source = source


class ProviderUnavailable(ProviderError):
    pass

