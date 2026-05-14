# MediaMTX + a tiny shell + curl/jq so MediaMTX hooks (`runOnReady`,
# `runOnNotReady`) can exec scripts that POST to `upstream-api-server`.
#
# The official `bluenviron/mediamtx:1.9.3` image is `FROM scratch` —
# it contains only the `mediamtx` Go binary, no shell, no coreutils.
# Hooks would silently fail. The `-ffmpeg-alpine` variant bundles
# ffmpeg/ffprobe and an alpine userland; we add curl, jq, bash, and
# coreutils for the hook scripts under `/hooks/`.
#
# Pin the upstream version explicitly — bumping MediaMTX changes hook
# env-var contracts and config keys, so re-test M4 hooks after any bump.

FROM bluenviron/mediamtx:1.9.3-ffmpeg-alpine

RUN apk add --no-cache curl jq bash coreutils
