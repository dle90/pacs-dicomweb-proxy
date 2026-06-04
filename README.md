# pacs-dicomweb-proxy

Lớp proxy đứng trước Orthanc — ingress **duy nhất** cho DICOMweb (WADO-RS / QIDO-RS / STOW-RS). Browser (qua [`pacs-viewer`](../pacs-viewer)) và gateway (STOW) đều đi qua đây; [`pacs`](../pacs) (Orthanc) nằm private, không expose.

Tách ra từ phần `/wado` proxy vốn nằm trong nginx của OHIF (bundle demo gộp ban đầu).

> **Bản dev hiện tại = nginx thuần, KHÔNG bảo mật** (build nhanh, chạy ngay). Bộ verify JWT (RS256 + bind `studyUid`) đã viết xong và **park ở [`auth/`](auth/)** — swap vào khi cần.

## Thành phần

| File | Vai trò |
|---|---|
| `nginx.conf` | Template: proxy `/wado/*` → Orthanc, cache per-instance, CORS, CORP, STOW streaming |
| `docker-entrypoint.sh` | `envsubst ${ORTHANC_BACKEND_URL}` → khởi động nginx |
| `Dockerfile` | `nginx:1.27-alpine` + gettext |
| `auth/` | Bộ verify JWT (OpenResty + lua-resty-jwt) — chưa bật, xem [auth/README.md](auth/README.md) |
| `cf-worker/` | (tuỳ chọn) Cloudflare Worker edge-cache — xem dưới |

## Đặc tính & scale

- **Stateless** → scale **ngang** (≥2 replica sau LB). CPU/RAM nhẹ: nginx **stream** chứ không buffer (`proxy_request_buffering off` cho STOW) → 1–2 vCPU / 1–2GB/replica là đủ; thêm replica cho concurrency, không phải thêm RAM.
- Việc nặng (decode/transcode) nằm ở Orthanc, không phải proxy.

## Chạy dev

```bash
docker network create medisync-pacs    # 1 lần (chung với pacs)
# bring up pacs (Orthanc) trước, rồi:
docker compose up --build
```

- Proxy publish `http://localhost:8080` → forward `/wado/*` tới `orthanc:8042` (qua network `medisync-pacs`).
- Health: `GET /healthz`.

## Biến cấu hình

| Env | Mặc định | Vai trò |
|---|---|---|
| `ORTHANC_BACKEND_URL` | `http://orthanc:8042` | Upstream Orthanc (substitute vào nginx.conf) |

(Các biến JWT — `RIS_JWT_PUBLIC_KEY`, `AUTH_ENABLED`, … — thuộc bản auth ở [`auth/`](auth/).)

## Cấu hình đã có sẵn

- **Cache per-instance** `Cache-Control: immutable` (SOPInstanceUID bất biến) → cuộn lại series instant.
- **CORS** `*` + **CORP cross-origin** (cần vì OHIF page chạy COEP: require-corp).
- **STOW**: `client_max_body_size 2g` + stream upload (gateway gửi cả study).

## TODO trước production

- [ ] **Bật bảo mật**: swap bộ verify JWT từ [`auth/`](auth/) (RS256 + bind `studyUid`) + wire viewer gắn token + RIS cấp view-token.
- [ ] **STOW write auth** — POST `/wado/studies` verify token gateway (client-credentials, scope `study.upload`).
- [ ] Siết **CORS allowlist** theo domain viewer thật (bỏ `*`).
- [ ] HTTPS termination (LB/cert) + rate limit + audit log.
- [ ] (tuỳ chọn) tách 2 deployment: ingest-proxy (STOW từ gateway) vs read-proxy (WADO từ browser).

## cf-worker (edge cache — tuỳ chọn)

`cf-worker/` là Cloudflare Worker cache 3-tier (immutable instance/frame, study-meta 10', bypass QIDO). Hiện `wrangler.jsonc` có `ORIGIN` trỏ tới URL OHIF Railway **cũ** — khi đổi sang topology mới, set `ORIGIN` về public URL của proxy này (hoặc Orthanc qua CF Tunnel). Deploy độc lập (`npm run deploy`), không nằm trong image proxy.
