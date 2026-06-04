-- medisync_auth.lua — DICOMweb access policy in front of Orthanc.
--
-- POLICY (gated by config sinh từ env trong jwt_config.lua):
--   • OPTIONS                          -> pass (CORS preflight).
--   • READ  (GET/HEAD: WADO-RS/QIDO)   -> nếu read_enabled: yêu cầu VIEW token bind đúng
--        study đang truy cập (token.studyUid == study trong URL request). Nếu tắt: PUBLIC.
--   • WRITE (POST/PUT/DELETE: STOW)    -> yêu cầu token hợp lệ từ một source cấu hình.
--
-- Token verify: RS256 + exp + iss (route theo iss) + aud. READ dùng read_audience (tuỳ chọn,
-- để trống = không kiểm aud); WRITE dùng audience của source. READ thêm bước bind-study.
-- Trên thành công: forward identity (X-Medisync-*), strip Authorization.

local _M = {}

local cfg        = require("jwt_config")          -- sinh bởi entrypoint từ env
local jwt        = require("resty.jwt")
local validators = require("resty.jwt-validators")

-- Per-source public key cache (name -> pem | false). Persist per worker.
local _keys = {}
local function key_for(src)
  local cached = _keys[src.name]
  if cached ~= nil then return cached end
  local f = io.open(src.public_key_path, "r")
  if not f then _keys[src.name] = false; return false end
  local k = f:read("*a"); f:close()
  _keys[src.name] = k
  return k
end

local function deny(status, msg)
  ngx.header["Access-Control-Allow-Origin"] = "*"
  ngx.header["Content-Type"] = "application/json"
  ngx.status = status
  ngx.say(string.format('{"error":%q}', msg))
  return ngx.exit(status)
end

-- Verify token với MỘT source. aud_override: nil = dùng src.audience (write/STOW);
-- "" = không kiểm aud; "X" = kiểm aud == "X" (read/view token).
local function try_source(token, src, aud_override)
  local pub = key_for(src)
  if not pub then return nil, "no key for source '" .. src.name .. "'" end
  jwt:set_alg_whitelist({ RS256 = 1 })   -- pin RS256: chặn alg:none / HS256 confusion
  local spec = { exp = validators.opt_is_not_expired() }
  local aud = aud_override
  if aud == nil then aud = src.audience end
  if aud and aud ~= "" then spec.aud = validators.opt_equals(aud) end
  if src.issuer and src.issuer ~= "" then spec.iss = validators.opt_equals(src.issuer) end
  local obj = jwt:verify(pub, token, spec)
  if obj.verified then return obj end
  return nil, obj.reason
end

-- Lấy Bearer token, route theo iss, verify qua source phù hợp. Trả (jwt_obj, source) hoặc deny().
local function authenticate(aud_override)
  local sources = cfg.sources or {}
  if #sources == 0 then return deny(500, "auth misconfigured: no token sources") end

  local hdr = ngx.var.http_authorization
  if not hdr then return deny(401, "missing bearer token") end
  local token = hdr:match("[Bb]earer%s+(.+)")
  if not token then return deny(401, "malformed authorization header") end

  -- Route theo iss: decode KHÔNG verify để đọc issuer, thử source khớp; fallback thử tất cả.
  local iss
  local ok, decoded = pcall(function() return jwt:load_jwt(token) end)
  if ok and decoded and decoded.payload then iss = decoded.payload.iss end

  local candidates = {}
  if iss and iss ~= "" then
    for _, s in ipairs(sources) do
      if s.issuer and s.issuer == iss then candidates[#candidates + 1] = s end
    end
  end
  if #candidates == 0 then candidates = sources end

  local jwt_obj, matched, last_reason
  for _, s in ipairs(candidates) do
    local obj, reason = try_source(token, s, aud_override)
    if obj then jwt_obj, matched = obj, s; break end
    last_reason = reason
  end
  if not jwt_obj then
    ngx.log(ngx.WARN, "medisync_auth: rejected (iss='", iss or "?", "'): ", last_reason or "?")
    return deny(401, "invalid token: " .. (last_reason or "verification failed"))
  end
  return jwt_obj, matched
end

-- StudyInstanceUID mà request đang truy cập: ưu tiên path /studies/<uid>, rồi query
-- (QIDO StudyInstanceUID / 0020000D, WADO-URI studyUID).
local function request_study_uid()
  local uri = ngx.var.uri or ""
  local s = uri:match("/studies/([%d][%d%.]*)")
  if s then return s end
  local args = ngx.req.get_uri_args()
  return args["StudyInstanceUID"] or args["0020000D"] or args["studyUID"]
end

-- ĐỌC CA: token phải bind đúng study đang xem (token.studyUid == study trong request).
local function enforce_study_binding(payload)
  local bound = payload.studyUid
  -- studyUid null/absent/empty = MASTER token → cho xem MỌI study + list-all (miễn chữ ký hợp lệ).
  -- Mục đích: cầm private key test pacs-viewer mà KHÔNG cần full luồng HIS-RIS. CHỈ dùng cho
  -- test/admin; production HIS phải LUÔN bind studyUid (token thường = scope đúng 1 ca).
  if type(bound) ~= "string" or bound == "" then
    return
  end
  local req_study = request_study_uid()
  if type(req_study) ~= "string" or req_study == "" then
    -- Request không khoá vào 1 study cụ thể (vd liệt kê tất cả) -> token bind-study không được phép.
    return deny(403, "request not scoped to the bound study")
  end
  if req_study ~= bound then
    ngx.log(ngx.WARN, "medisync_auth: study mismatch req='", req_study, "' token='", bound, "'")
    return deny(403, "token not valid for this study")
  end
end

function _M.verify()
  if not cfg.enabled then return end

  local method = ngx.req.get_method()
  if method == "OPTIONS" then return end   -- CORS preflight

  local is_read = (method == "GET" or method == "HEAD")

  -- READ public khi chưa bật bảo mật đọc ("đọc ca: public").
  if is_read and not cfg.read_enabled then return end

  if is_read then
    -- Bảo mật ĐỌC CA: VIEW token bind đúng studyUid.
    local jwt_obj, matched = authenticate(cfg.read_audience)
    local payload = jwt_obj.payload or {}
    enforce_study_binding(payload)
    ngx.req.set_header("X-Medisync-Token-Source", matched.name)
    ngx.req.set_header("X-Medisync-User", payload.sub or "")
    ngx.req.set_header("X-Medisync-User-Uuid", payload.uuid or "")
    ngx.req.clear_header("Authorization")
    return
  end

  -- WRITE (STOW): yêu cầu token; forward identity + stash cho post-STOW labeling.
  local jwt_obj, matched = authenticate(nil)
  local payload = jwt_obj.payload or {}
  ngx.req.set_header("X-Medisync-Token-Source", matched.name)   -- "his" | "telerad"
  ngx.req.set_header("X-Medisync-User", payload.sub or "")
  ngx.req.set_header("X-Medisync-User-Uuid", payload.uuid or "")
  ngx.req.clear_header("Authorization")

  local uri = ngx.var.uri or ""
  if method == "POST" and uri:find("/studies", 1, true) then
    ngx.ctx.medisync_is_stow  = true
    ngx.ctx.medisync_company  = payload.companyUuid  or ""
    ngx.ctx.medisync_facility = payload.facilityUuid or ""
  end
end

return _M
