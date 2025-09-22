# Single stage - just copy pre-built files
FROM alpine:3.20

RUN apk add --no-cache ca-certificates

WORKDIR /app

# Copy the pre-built binary (build locally with: zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast)
COPY zig-out/bin/htmz ./htmz

# Copy shared library
COPY .zig-cache/o/77b812d70083cc112eb7e0e67c512219/libfacil.io.so /usr/lib/

# Copy public assets
COPY public/ ./public/

# Set environment
ENV PORT=8080
# SECRET_KEY should be provided at runtime via -e SECRET_KEY=your-key

# Expose port
EXPOSE 8080

# Create non-root user for security (Alpine syntax)
RUN adduser -D -s /bin/false appuser && \
    chown -R appuser:appuser /app
USER appuser

CMD ["/app/htmz"]