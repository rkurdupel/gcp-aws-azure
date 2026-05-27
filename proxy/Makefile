.PHONY: build run clean tidy

# Cross-compile for Linux amd64 (target VM architecture)
build: tidy
	GOOS=linux GOARCH=amd64 go build -o proxy-linux .

# Local run (uses host OS)
run: tidy
	go run .

tidy:
	go mod tidy

clean:
	rm -f proxy-linux proxy
