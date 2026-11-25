FROM golang:1.26.0-alpine AS build
WORKDIR /src
COPY server/go.* ./
RUN go mod download
COPY server/ ./
COPY infra/t34/drill/ ./cmd/t34/
RUN CGO_ENABLED=0 go build -trimpath -o /out/api ./cmd/api && CGO_ENABLED=0 go build -trimpath -o /out/drill ./cmd/t34
FROM scratch AS api
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/api /api
ARG RELEASE
LABEL org.opencontainers.image.version=$RELEASE
USER 65532:65532
ENTRYPOINT ["/api"]
FROM scratch AS drill
COPY --from=build /out/drill /drill
USER 65532:65532
ENTRYPOINT ["/drill"]
