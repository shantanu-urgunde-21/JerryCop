.PHONY: run test build

# Run the JerryCop proxy
run:
	go run ./cmd/main.go

# Run tests
test:
	go test -v ./...

# Build binary
build:
	go build -o bin/jerrycop.exe ./cmd/main.go
