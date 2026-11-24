default:
    @just --list

build:
    zig build

test:
    zig build test

run *args:
    zig build run -- {{args}}

sarif path="src":
    zig build run -- --format=sarif {{path}}

check: build
    ./zig-out/bin/codestyle --profile=default src tests/runner_test.zig build.zig
    ./zig-out/bin/codestyle --profile=strict src tests/runner_test.zig build.zig
    ./zig-out/bin/codestyle --profile=migration src tests/runner_test.zig build.zig

clean:
    rm -rf zig-out .zig-cache
