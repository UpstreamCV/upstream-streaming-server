# MediaMTX + a real userland so MediaMTX hooks (`runOnReady`,
# `runOnNotReady`) can exec scripts that POST to `upstream-api-server`.
#
# The official `bluenviron/mediamtx:1.9.3` image is `FROM scratch` —
# only the `mediamtx` Go binary, no shell, no coreutils. Hooks would
# silently fail to exec. The `-ffmpeg` variant adds ffmpeg/ffprobe but
# is also `FROM scratch`. There is no upstream alpine variant.
#
# Solution: build our own image from alpine, install the runtime deps
# we need (ffmpeg, curl, jq, bash, coreutils), and copy the `mediamtx`
# binary across from the official image's named stage. Multi-arch is
# preserved because both base images are multi-arch.
#
# Pin the upstream version explicitly — bumping MediaMTX changes hook
# env-var contracts and config keys, so re-test M4 hooks after any bump.

FROM bluenviron/mediamtx:1.9.3 AS mediamtx-bin

FROM alpine:3.20

RUN apk add --no-cache ffmpeg curl jq bash coreutils tzdata

COPY --from=mediamtx-bin /mediamtx /mediamtx
# The official image keeps a default mediamtx.yml at /mediamtx.yml; we
# mount our own over /mediamtx.yml via docker-compose, but copy the
# upstream default to a side path so a bare `docker run` still works
# for inspection and as a reference for upstream defaults.
COPY --from=mediamtx-bin /mediamtx.yml /mediamtx.yml.default

ENTRYPOINT ["/mediamtx"]
