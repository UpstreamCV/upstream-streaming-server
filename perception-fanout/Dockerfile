# perception-fanout — high-rate perception snapshot fan-out sidecar.
#
# slim (Debian) rather than alpine: uvicorn[standard]'s uvloop/httptools
# ship manylinux wheels, so no musl source builds. Runs as a non-root
# user from day one (unlike the mediamtx container, whose non-root work
# is scheduled M11.3).
FROM python:3.12-slim

RUN useradd --create-home --uid 10001 fanout

WORKDIR /srv
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

USER fanout
EXPOSE 8990

# Protocol-level ping/pong keepalive (20s/20s) — the wire contract's
# only keepalive; there is no application-level heartbeat frame.
#
# --no-access-log is a SECURITY setting, not a tuning knob: subscriber
# tokens ride the WS query string (browsers cannot set WS headers), so
# uvicorn's access log would record `GET /v1/subscribe?token=upt1...`
# on every connect. The structured JSON event lines (app/events.py) are
# the sanctioned observability instead. The e2e test greps for exactly
# this leak (scripts/dev/test_perception_fanout.sh case 8).
CMD ["uvicorn", "app.asgi:app", \
     "--host", "0.0.0.0", "--port", "8990", \
     "--ws-ping-interval", "20", "--ws-ping-timeout", "20", \
     "--no-server-header", "--no-access-log"]
