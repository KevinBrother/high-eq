FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git curl unzip xz-utils libglu1-mesa && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch 3.38.10 https://github.com/flutter/flutter.git /opt/flutter && \
    test "$(git -C /opt/flutter rev-parse HEAD)" = c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80
ENV PATH=/opt/flutter/bin:$PATH CI=true FLUTTER_SUPPRESS_ANALYTICS=true
RUN flutter precache --web
WORKDIR /src
COPY admin/ .
RUN flutter pub get --enforce-lockfile && flutter build web --release --no-pub --no-web-resources-cdn
FROM nginx:1.28.0-alpine
COPY --chmod=0444 infra/t34/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /src/build/web /usr/share/nginx/html
ARG RELEASE
RUN printf '%s\n' "$RELEASE" > /usr/share/nginx/html/release.txt && chmod -R a+rX /usr/share/nginx/html
USER 101:101
ENTRYPOINT ["nginx", "-g", "daemon off;"]
