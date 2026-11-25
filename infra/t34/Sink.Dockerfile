FROM golang:1.26.0-alpine AS build
WORKDIR /src
COPY infra/t34/sink/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/sink ./main.go
FROM scratch
COPY --from=build /out/sink /sink
ARG RELEASE
LABEL org.opencontainers.image.version=$RELEASE
USER 65532:65532
ENTRYPOINT ["/sink"]
