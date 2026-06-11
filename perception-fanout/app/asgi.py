"""ASGI entry point: builds the app from environment variables.

Kept separate from app.main so tests can import create_app/Settings
without triggering the fail-loud env validation at import time.

    uvicorn app.asgi:app --host 0.0.0.0 --port 8990 \
        --ws-ping-interval 20 --ws-ping-timeout 20
"""

from .main import Settings, create_app

app = create_app(Settings.from_env())
