# syntax=docker/dockerfile:1.7

ARG JELLYFIN_IMAGE=jellyfin/jellyfin:10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db

FROM ${JELLYFIN_IMAGE} AS seed

USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/satra-demo
COPY scripts/maestro/maestro_fixtures.py scripts/maestro/maestro_real_jellyfin.py scripts/maestro/prepare_maestro_media.py ./
COPY .maestro/jellyfin-demo/seed.sh ./seed.sh

ARG SATRA_DEMO_MEDIA_BASE_URL=https://demo-files.plezy.app/media-samples/
ARG SATRA_DEMO_MEDIA_REVISION=2026-07-14
ARG SATRA_DEMO_MEDIA_DURATION=300
RUN test -n "${SATRA_DEMO_MEDIA_REVISION}" \
    && python3 maestro_real_jellyfin.py download-codecs \
        --base-url "${SATRA_DEMO_MEDIA_BASE_URL}" \
        --output-dir /tmp/satra-codecs \
    && PATH="/usr/lib/jellyfin-ffmpeg:${PATH}" python3 prepare_maestro_media.py \
        /tmp/satra-codecs /tmp/satra-codecs-prepared \
        --duration "${SATRA_DEMO_MEDIA_DURATION}" \
        --extend av1_opus_ass_srt.mkv \
        --extend h264_eac3_multisub.mkv \
        --extend hevc10_flac_ass.mkv \
    && python3 maestro_real_jellyfin.py prepare \
        --output-dir /media \
        --codec-source-dir /tmp/satra-codecs-prepared \
        --include-codecs \
    && rm -rf /tmp/satra-codecs /tmp/satra-codecs-prepared __pycache__ \
    && chmod -R a=rX /media

RUN ./seed.sh

FROM ${JELLYFIN_IMAGE}

LABEL org.opencontainers.image.title="Satra Jellyfin demo server" \
      org.opencontainers.image.description="Ready-to-run Jellyfin server with Satra's deterministic codec demo catalog" \
      org.opencontainers.image.source="https://github.com/rahhing/Satra"

COPY --from=seed /media /media
COPY --from=seed /opt/satra-demo/seed-config /opt/satra-demo/seed-config
COPY .maestro/jellyfin-demo/entrypoint.sh /usr/local/bin/satra-demo-entrypoint

RUN chmod 0755 /usr/local/bin/satra-demo-entrypoint \
    && chmod -R a=rX /media /opt/satra-demo/seed-config

ENV TZ=UTC \
    JELLYFIN_PublishedServerUrl=http://localhost:8096

EXPOSE 8096
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/satra-demo-entrypoint"]
