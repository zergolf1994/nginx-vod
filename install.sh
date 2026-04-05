#!/usr/bin/env bash
# v3: Install nginx-vod-module with patch for mapped+remote mode on Ubuntu 24.04
# Uses official Kaltura nginx-vod-module with fix for "upstream is null" issue
# Reference: https://github.com/kaltura/nginx-vod-module/issues/1551
set -euo pipefail

# ===================== Configuration =====================
SERVER_PORT="${SERVER_PORT:-8889}"
SEGMENT_DUR="${SEGMENT_DUR:-4}"
MEDIA_ROOT="${MEDIA_ROOT:-/home/files}"
SEGMENT_DUR_MS=$((SEGMENT_DUR * 1000))

# ====================== Helpers =========================
log(){ printf "\n\033[1;32m[INFO]\033[0m %s\n" "$*"; }
err(){ printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*"; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || err "Run as root (sudo)"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ====================== Main ===========================
need_root

log "Installing dependencies..."
apt update
DEBIAN_FRONTEND=noninteractive apt -y --no-install-recommends install \
  build-essential git curl ca-certificates \
  nginx \
  libpcre2-dev zlib1g-dev libssl-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libavfilter-dev \
  libxml2-dev libxslt1-dev libgd-dev \
  nload
  
NGX_VERSION="$(nginx -v 2>&1 | sed -n 's#.*/\([0-9.]\+\).*#\1#p')"
[[ -n "${NGX_VERSION}" ]] || err "Cannot detect nginx version"
log "Detected nginx ${NGX_VERSION}"

WORKDIR="${HOME}/build/nginx-vod"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Download nginx source
if [[ ! -f "nginx-${NGX_VERSION}.tar.gz" ]]; then
  log "Downloading nginx-${NGX_VERSION} source..."
  curl -fsSLo "nginx-${NGX_VERSION}.tar.gz" \
    "https://nginx.org/download/nginx-${NGX_VERSION}.tar.gz"
fi
rm -rf "nginx-${NGX_VERSION}"
tar xzf "nginx-${NGX_VERSION}.tar.gz"

# Clone Kaltura nginx-vod-module
log "Cloning Kaltura nginx-vod-module..."
rm -rf nginx-vod-module
git clone --depth=1 https://github.com/kaltura/nginx-vod-module.git

# Apply patch for mapped+remote mode
log "Applying patch for 'upstream is null' issue..."
cd nginx-vod-module

# Backup original
cp ngx_child_http_request.c ngx_child_http_request.c.orig

# Fix in ngx_child_request_wev_handler: if (u == NULL) -> if (u == NULL && sr->out == NULL)
sed -i '/ngx_child_request_wev_handler/,/^}/ s/if (u == NULL)/if (u == NULL \&\& sr->out == NULL)/' ngx_child_http_request.c

# Fix in ngx_child_request_initial_wev_handler: if (u == NULL) -> if (u == NULL && r->out == NULL)
sed -i '/ngx_child_request_initial_wev_handler/,/^}/ s/if (u == NULL)/if (u == NULL \&\& r->out == NULL)/' ngx_child_http_request.c

# Verify patches
if ! grep -q "sr->out == NULL" ngx_child_http_request.c; then
  err "Patch 1 failed - could not apply fix for ngx_child_request_wev_handler"
fi
if ! grep -q "r->out == NULL" ngx_child_http_request.c; then
  err "Patch 2 failed - could not apply fix for ngx_child_request_initial_wev_handler"
fi
log "Patches applied successfully"

# Configure and build
cd "${WORKDIR}/nginx-${NGX_VERSION}"
log "Configuring nginx with vod module..."
./configure --with-compat --add-dynamic-module=../nginx-vod-module

log "Building module..."
make -j"$(nproc)" modules

[[ -f objs/ngx_http_vod_module.so ]] || err "Module build failed"

log "Installing module..."
install -d /usr/lib/nginx/modules
install -m 0644 objs/ngx_http_vod_module.so /usr/lib/nginx/modules/

# Prepare directories
log "Preparing directories..."
install -d -m 0755 "${MEDIA_ROOT}"
install -d -m 0755 /var/cache/nginx/vod
chown -R www-data:www-data "${MEDIA_ROOT}" /var/cache/nginx/vod

# Write nginx.conf
log "Writing /etc/nginx/nginx.conf..."
[[ -f /etc/nginx/nginx.conf ]] && \
  cp /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"

cat >/etc/nginx/nginx.conf <<'NGX'
load_module /usr/lib/nginx/modules/ngx_http_vod_module.so;

user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log info;

events {
  worker_connections 4096;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 60;

  gzip on;
  gzip_types application/vnd.apple.mpegurl application/dash+xml text/xml text/vtt application/json;

  # VOD global settings
  aio threads;
  vod_initial_read_size 64m;
  vod_max_metadata_size 512m;
  vod_metadata_cache metadata_cache 2048m;
  vod_response_cache response_cache 512m;
  vod_output_buffer_pool 4m 64;
  vod_performance_counters perf_counters;
  vod_last_modified 'Sun, 19 Nov 2000 08:52:00 GMT';
  vod_last_modified_types *;
  
  # Support for large files (12-20GB, 12+ hours)
  vod_max_frame_count 5000000;

  vod_segment_duration __SEGMENT_DUR_MS__;
  vod_manifest_segment_durations_mode accurate;
  vod_segment_count_policy last_rounded;
  
  vod_force_continuous_timestamps on;
  vod_ignore_edit_list on;

  # DNS resolver
  resolver 1.1.1.1 1.0.0.1 valid=300s;
  resolver_timeout 5s;

  # Log format
  log_format vod_log '$remote_addr "$request" $status vod:$vod_status cf_ray:$http_cf_ray';
  log_format public_log '$remote_addr "$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent" cf_ray:$http_cf_ray';
  access_log /var/log/nginx/access.log vod_log;

  include /etc/nginx/conf.d/*.conf;
}
NGX

# Apply variable substitutions to nginx.conf
sed -i "s/__SEGMENT_DUR_MS__/${SEGMENT_DUR_MS}/" /etc/nginx/nginx.conf

# Write vod.conf (mapped mode with local files)
log "Writing /etc/nginx/conf.d/vod.conf..."
cat >/etc/nginx/conf.d/vod.conf <<'NGX'
upstream jsonserver {
  server 127.0.0.1:8888;
  keepalive 32;
}

server {
  listen 8889;
  server_name _;

  # vod mode configuration
  vod_mode mapped;
  vod_upstream_location /json;

  # mapping cache (specific to this server)
  vod_mapping_cache mapping_cache 512m;
  
  # NOTE: response_cache and metadata_cache are already defined in nginx.conf
  # Do NOT redefine them here
  
  vod_max_mapping_response_size 16m;
  
  # IMPORTANT: Increase buffer for upstream response headers
  vod_max_upstream_headers_size 8k;

  # gzip manifests
  gzip on;
  gzip_types application/vnd.apple.mpegurl application/dash+xml;

  # file handle caching
  open_file_cache max=1000 inactive=5m;
  open_file_cache_valid 2m;
  open_file_cache_min_uses 1;
  open_file_cache_errors on;
  
  client_body_buffer_size 256k;
  client_max_body_size 500m;
  client_body_timeout 90s;

  location = /healthz {
    return 200 "ok\n";
  }

  # JSON mapping - /json/{protocol}/file.json -> localhost:8888/file.json
  location ^~ /json/ {
    # internal; # Uncomment for production security
    
    rewrite ^/json/[^/]+/(.*)$ /$1 break;
    
    proxy_pass http://jsonserver;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host 127.0.0.1;
    
    proxy_connect_timeout 10s;
    proxy_send_timeout 10s;
    proxy_read_timeout 10s;
    
    proxy_buffer_size 128k;
    proxy_buffers 16 128k;
    proxy_busy_buffers_size 256k;
  }

  # HLS streaming against local files (mapped via JSON)
  location /hls/ {
    vod hls;
    vod_hls_output_iframes_playlist off;
    
    add_header Access-Control-Allow-Headers '*';
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range';
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS';
    add_header Access-Control-Allow-Origin '*';
    
    location ~ \.m3u8$ {
      vod hls;
      vod_hls_output_iframes_playlist off;
      add_header Cache-Control "public, max-age=3600" always;
      add_header Access-Control-Allow-Origin '*' always;
      expires 1h;
    }
    
    location ~ \.ts$ {
      vod hls;
      add_header Cache-Control "public, max-age=31536000, immutable" always;
      add_header Access-Control-Allow-Origin '*' always;
      expires 1y;
    }
    
    expires 1h;
  }

  # DASH streaming
  location /dash/ {
    vod dash;
    
    add_header Access-Control-Allow-Headers '*';
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range';
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS';
    add_header Access-Control-Allow-Origin '*';
    
    expires 1h;
  }

  # Thumbnail capture
  location /thumb/ {
    vod thumb;
    
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Allow-Origin '*' always;
    add_header Content-Type 'image/jpeg' always;
    
    add_header Cache-Control "public, max-age=31536000, immutable" always;
    expires 1y;
    
    if ($request_method = OPTIONS) {
      return 204;
    }
  }

  location /vod_status {
    vod_status;
    access_log off;
  }

  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log info;
}
NGX

# Apply variable substitutions to vod.conf
sed -i "s/listen 8889;/listen ${SERVER_PORT};/" /etc/nginx/conf.d/vod.conf

log "Writing /etc/nginx/conf.d/local.conf..."
cat >/etc/nginx/conf.d/local.conf <<'NGX'
# Public proxy server (port 80)
server {
  listen 80;
  server_name _;

  # Default index — fake OSS error
  location = / {
    default_type application/xml;
    return 404 '<?xml version="1.0" encoding="UTF-8"?>\n<Error>\n  <Code>NoSuchKey</Code>\n  <Message>The specified key does not exist.</Message>\n  <RequestId>69870680B0CAA23639B92A8C</RequestId>\n  <HostId>surrit.oss-eu-central-1.aliyuncs.com</HostId>\n  <Key>/</Key>\n  <EC>0026-00000001</EC>\n  <RecommendDoc>https://api.alibabacloud.com/troubleshoot?q=0026-00000001</RecommendDoc>\n</Error>';
  }

  # Custom 404 — fake OSS error
  error_page 404 /custom_404;
  location = /custom_404 {
    internal;
    default_type application/xml;
    return 404 '<?xml version="1.0" encoding="UTF-8"?>\n<Error>\n  <Code>NoSuchKey</Code>\n  <Message>The specified key does not exist.</Message>\n  <RequestId>69870680B0CAA23639B92A8C</RequestId>\n  <HostId>surrit.oss-eu-central-1.aliyuncs.com</HostId>\n  <Key>$request_uri</Key>\n  <EC>0026-00000001</EC>\n  <RecommendDoc>https://api.alibabacloud.com/troubleshoot?q=0026-00000001</RecommendDoc>\n</Error>';
  }

  # Static files from /home/files
  location /static/ {
    alias /home/files/;
    autoindex on;
    
    add_header Access-Control-Allow-Origin * always;
  }

  # Proxy HLS streaming - support both /test.json/playlist.m3u8 and /test/playlist.m3u8
  # Pattern 1: /filename.json/playlist.m3u8 -> /hls/filename.json/master.m3u8
  location ~ ^/([^/]+\.json)/playlist\.m3u8$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1/master.m3u8;
    
    # Enable buffering for sub_filter to work
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    
    # Hide upstream CORS headers to avoid duplicates (but NOT Cache-Control)
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS headers once
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
    
    # Rewrite URLs in playlist
    sub_filter_types application/vnd.apple.mpegurl;
    sub_filter '/hls/' '/';
    sub_filter '/index-v1-a1.m3u8' '/video.m3u8';
    sub_filter_once off;
  }

  # Pattern 2: /filename.json/index.m3u8 or any .m3u8
  location ~ ^/([^/]+\.json)/(.+\.m3u8)$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/hls/$1/$2;
    
    # Enable buffering for sub_filter to work
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    
    # Hide upstream CORS headers (but NOT Cache-Control)
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS headers
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
    
    # Rewrite URLs in playlist from /hls/file.json/ to /file.json/
    sub_filter_types application/vnd.apple.mpegurl;
    sub_filter '/hls/' '/';
    sub_filter_once off;
  }

  # Pattern 3: /filename.json/segments (ts, m4s, etc.)
  location ~ ^/([^/]+\.json)/(.+)$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/hls/$1/$2;
    
    # Hide upstream CORS headers
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS headers
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
  }

  # Pattern 4: Friendly URLs without .json extension
  # /test/master.m3u8 -> /hls/test.json/master.m3u8
  location ~ ^/([^/]+)/master\.m3u8$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1.json/master.m3u8;
    
    # Enable buffering for sub_filter to work
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    
    # Hide upstream CORS headers (but NOT Cache-Control)
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS headers
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
    
    # Rewrite URLs in playlist from /hls/file.json/ to /file/
    sub_filter_types application/vnd.apple.mpegurl text/plain;
    sub_filter '/hls/' '/';
    sub_filter '.json/index-v1-a1.m3u8' '/video.m3u8';
    sub_filter_once off;
  }

  # Pattern 5: /test/video.m3u8 -> /hls/test.json/index-v1-a1.m3u8
  location ~ ^/([^/]+)/video\.m3u8$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1.json/index-v1-a1.m3u8;
    
    # Enable buffering for sub_filter to work
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    
    # Hide upstream CORS headers (but NOT Cache-Control - let VOD server handle it)
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS headers
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
    
    # Rewrite segment URLs from /hls/file.json/seg-1-v1-a1.ts to /file/v-1.jpeg
    sub_filter_types application/vnd.apple.mpegurl text/plain;
    sub_filter '/hls/' '/';
    sub_filter '.json/seg-' '/v-';
    sub_filter '-v1-a1.ts' '.jpeg';
    sub_filter_once off;
  }

   # Pattern 6: /xxx/v-2.jpeg -> /hls/xxx.json/seg-2-v1-a1.ts
  # Rate limited to prevent mass downloading while allowing normal streaming
  location ~ ^/([^/]+)/v-(\d+)\.jpeg$ {
    # Limit bandwidth to 3MB/s per connection (compensate for buffering overhead)
    limit_rate 3m;
    limit_rate_after 100k;  # Full speed for first 100KB, then throttle
    
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/hls/$1.json/seg-$2-v1-a1.ts;
    
    # Hide upstream headers
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    proxy_hide_header Content-Type;
    proxy_hide_header Cache-Control;
    proxy_hide_header Expires;
    proxy_hide_header last-modified;
    proxy_hide_header Server;
    proxy_hide_header Timing-Allow-Origin;
    proxy_hide_header Vary;
    proxy_hide_header Accept-Ranges;
    proxy_hide_header Connection;
    #proxy_hide_header ETag;
    proxy_hide_header Date;
    
    # Set headers to mimic image/jpeg file
    add_header Content-Type 'image/jpeg' always;
    add_header Accept-Ranges 'bytes' always;
    add_header Access-Control-Allow-Origin '*' always;
    add_header Access-Control-Allow-Credentials 'false' always;
    add_header Cache-Control 'public, max-age=31536000, immutable' always;
    #add_header Connection 'keep-alive' always;
    add_header Timing-Allow-Origin '*' always;
    add_header Vary 'Accept-Encoding' always;
    server_tokens off;
  }

  # Pattern 7: Thumbnail with time parameter
  # /thumb/xxx-30.jpg -> /thumb/xxx.json/thumb-30000.jpg (30 seconds = 30000ms)
  location ~ ^/thumb/([^/]+)-(\d+)\.jpg$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    # Convert seconds to milliseconds
    set $time_sec $2;
    set $time_ms "${time_sec}000";
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/thumb/$1.json/thumb-$time_ms.jpg;
    
    # Hide upstream CORS headers
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS and Cache headers
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
    add_header Cache-Control 'public, max-age=31536000, immutable' always;
  }

  # Pattern 8: Thumbnail without time parameter (default to 1 second)
  # /thumb/xxx.jpg -> /thumb/xxx.json/thumb-1000.jpg
  location ~ ^/thumb/([^/]+)\.jpg$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/thumb/$1.json/thumb-1000.jpg;
    
    # Hide upstream CORS headers
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS and Cache headers
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
    add_header Cache-Control 'public, max-age=31536000, immutable' always;
  }

  # Pattern 9: Catch-all for other files (MUST be AFTER thumbnail patterns)
  # /test/anything -> /hls/test.json/anything
  location ~ ^/([^/]+)/(.*)$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }
    
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1.json/$2;
    
    # Enable buffering for sub_filter to work
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;
    
    # Hide upstream CORS headers
    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    
    # Set CORS headers
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
    
    # Rewrite URLs in playlists: /hls/anything.json/ -> /anything/
    sub_filter_types application/vnd.apple.mpegurl text/plain;
    sub_filter '/hls/' '/';
    sub_filter '.json/' '/';
    sub_filter 'seg-' 'v-';
    sub_filter '-v1-a1.ts' '.jpeg';
    sub_filter_once off;
  }

  location = /healthz {
    return 200 "ok\n";
  }

  access_log /var/log/nginx/public.log public_log;
  error_log /var/log/nginx/public-error.log warn;
}
NGX

# Apply variable substitutions to local.conf
sed -i "s|127.0.0.1:8889|127.0.0.1:${SERVER_PORT}|g" /etc/nginx/conf.d/local.conf

# Test and restart
log "Testing nginx configuration..."
nginx -t

log "Restarting nginx..."
systemctl enable nginx
systemctl restart nginx

# Cleanup build artifacts
log "Cleaning up build directory..."
rm -rf "${WORKDIR}"

log "Installation complete!"
log ""
log "Usage:"
log "  1. Place your video file:"
log "     cp your-video.mp4 ${MEDIA_ROOT}/video.mp4"
log ""
log "  2. Create JSON mapping file:"
log "     cat > ${MEDIA_ROOT}/test.json <<'EOF'"
log '{"sequences":[{"clips":[{"type":"source","path":"'${MEDIA_ROOT}'/video.mp4"}]}]}'
log "     EOF"
log ""
log "  3. Access HLS stream:"
log "     Direct (with .json): http://YOUR_IP/test.json/playlist.m3u8"
log "     Friendly (no .json): http://YOUR_IP/test/playlist.m3u8"
log "     Internal access:     http://YOUR_IP:${SERVER_PORT}/hls/test.json/master.m3u8"
log ""
log "  4. Debugging:"
log "     Check JSON server:   curl http://127.0.0.1:8888/test.json"
log "     Check VOD server:    curl http://127.0.0.1:${SERVER_PORT}/healthz"
log "     Check public proxy:  curl http://127.0.0.1/healthz"
log "     View nginx logs:     tail -f /var/log/nginx/error.log"
log "     View VOD status:     http://YOUR_IP:${SERVER_PORT}/vod_status"
log ""
log "Note: Mapped mode uses local files from ${MEDIA_ROOT}"
