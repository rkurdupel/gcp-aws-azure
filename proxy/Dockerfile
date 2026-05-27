FROM golang:1.24-alpine AS builder

RUN apk add --no-cache ca-certificates

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -trimpath \
    -buildvcs=false \
    -ldflags="-s -w -buildid=" \
    -o /proxy .

FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /proxy /proxy

EXPOSE 8080
USER 65532:65532

ENTRYPOINT ["/proxy"]
