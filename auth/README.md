# auth/ — JWT verifier, 2 token sources (HIS + Telerad) — parked, chưa bật

Bộ verify JWT cho `pacs-dicomweb-proxy`. Để riêng vì dev đang chạy proxy nginx thuần không bảo mật. Khi cần bật, swap bộ này vào.

**Chấp nhận token từ 2 hệ thống**: **HIS** và **Telerad** — mỗi nguồn có **public key + issuer + audience riêng**. Verifier route theo claim `iss`.

## Có gì
| File | Vai trò |
|---|---|
| `Dockerfile` | `openresty/openresty:alpine-fat` + `opm get SkyLothar/lua-resty-jwt` |
| `nginx.conf` | OpenResty, `access_by_lua` → `medisync_auth.verify()` trên `/wado` |
| `lua/medisync_auth.lua` | Multi-source verify: route theo `iss` → verify RS256 + `exp`/`aud`/`iss` + bind `studyUid` |
| `docker-entrypoint.sh` | Materialize 2 key (HIS+Telerad) + sinh `jwt_config.lua` (`sources` list) |

## Cách verify (khi bật)
GET/HEAD `/wado/*` cần `Authorization: Bearer <JWT>`. Verifier:
1. Decode (chưa verify) đọc `iss` → chọn **source** có `issuer` khớp (không khớp/không có `iss` → thử lần lượt mọi source).
2. Verify với public key của source đó: **RS256** (pin alg), `exp`, `aud`==source.audience, `iss`==source.issuer.
3. **Bind `studyUid`** == StudyInstanceUID trong URL (áp dụng cho cả 2 source).
4. OK → strip `Authorization`, forward `X-Medisync-Token-Source` (`his`|`telerad`) + `X-Medisync-User`/`-Uuid`/`-Study`.

Claims dùng: `iss`, `aud`, `sub`, `uuid`, `studyUid`. POST STOW chưa enforce (`TODO(stow)`).

## Cấu hình 2 nguồn (env — config variable, KHÔNG bake)
| HIS | Telerad |
|---|---|
| `HIS_JWT_PUBLIC_KEY` (hoặc `_BASE64`) | `TELERAD_JWT_PUBLIC_KEY` (hoặc `_BASE64`) |
| `HIS_JWT_ISSUER` | `TELERAD_JWT_ISSUER` |
| `HIS_JWT_AUDIENCE` | `TELERAD_JWT_AUDIENCE` |

`AUTH_ENABLED=true` + ít nhất 1 source có key. `issuer` mỗi nguồn **nên set** để route chính xác theo `iss` (nếu rỗng → fallback thử mọi key).

Public key **HIS** hiện có (2047-bit RSA — prod nên thay 2048/3072-bit sạch):
```
-----BEGIN PUBLIC KEY-----
MIIBITANBgkqhkiG9w0BAQEFAAOCAQ4AMIIBCQKCAQBLYR4xlru0jnp95ga0wPp5
62lanl36SRxtIXbFfr0K/bMwApgTw1+bMuqVNlGJIyMf9mW3R+bCyx3LDTC62AWh
pk1QZr0BXq5+DD93odOzc3W1aA0RWXr90vXCqAOA0JqYHAL6++4JtXlmlq1ikSMv
eRJl+V3c/qJljmRPFflfv/ySpW8WnoqK3bNjULZzCxtLMsbIVvMvUMl0uZ9i6bRv
zwzd5KmJYl94Wy2wu044hpnFcRZkW4qxpFjatwQ40J1kAP/FXiKQ6CnPtWHkqtFD
6qy1r781qJyRGtZHRgS9dUCy7vEx4JAM2fqI4skmqRHnPirhGXKTU3EEpLfpTEqV
AgMBAAE=
-----END PUBLIC KEY-----
```
Telerad key: lấy từ hệ Telerad (chưa có).

## Bật bảo mật (khi sẵn sàng)
1. `pacs-dicomweb-proxy/docker-compose.yml`: đổi `build: .` → `build: ./auth`, thêm env:
   ```yaml
   environment:
     ORTHANC_BACKEND_URL: "http://orthanc:8042"
     AUTH_ENABLED: "true"
     # HIS
     HIS_JWT_ISSUER: "https://his-core.medisync.vn"
     HIS_JWT_AUDIENCE: "medisync-viewer"
     HIS_JWT_PUBLIC_KEY: |
       -----BEGIN PUBLIC KEY-----
       ...
       -----END PUBLIC KEY-----
     # Telerad
     TELERAD_JWT_ISSUER: "https://telerad.example/..."
     TELERAD_JWT_AUDIENCE: "medisync-viewer"
     TELERAD_JWT_PUBLIC_KEY: |
       -----BEGIN PUBLIC KEY-----
       ...
       -----END PUBLIC KEY-----
   ```
   (Hoặc `railway.json` dockerfilePath → `auth/Dockerfile`.)
2. Viewer gắn token (HIS hoặc Telerad) vào `Authorization: Bearer`.
3. Rebuild. Test mỗi nguồn:
   ```bash
   curl -H "Authorization: Bearer <his_or_telerad_token>" \
     "http://localhost:8080/wado/studies/<studyUID>/metadata"
   ```

## Lưu ý kỹ thuật
- `opm get` cần mạng lúc build. Xác nhận API lua-resty-jwt: `set_alg_whitelist`, `load_jwt`, validators `opt_equals`/`opt_is_not_expired`.
- `aud` dạng **mảng** → đổi `opt_equals` → validator `contains`.
- Nếu 1 nguồn (vd Telerad) phát token **không** bind study → gate riêng phần `studyUid` theo `matched.name`.
- 2 source nên có **`iss` khác nhau** để route O(1); nếu trùng/không có thì verifier vẫn chạy (thử mọi key) nhưng kém tường minh.
