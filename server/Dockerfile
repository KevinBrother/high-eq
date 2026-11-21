FROM golang:1.26-alpine AS toolchain
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /api ./cmd/api

FROM scratch AS runtime
COPY --from=toolchain /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=toolchain /api /api
USER 65532:65532
ENTRYPOINT ["/api"]
