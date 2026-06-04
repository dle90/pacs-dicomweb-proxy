-- medisync_label.lua — apply tenant LABELS to a study after a successful STOW.
--
-- The label is built from the VERIFIED JWT (not from DICOM tags): the proxy knows
-- companyUuid/facilityUuid from the token, and tags the just-stored study so it can
-- later be enumerated for tenant find / transfer / delete. Labels:
--     companyUuid_<companyUuid>   facilityUuid_<facilityUuid>
-- (Orthanc labels only allow [A-Za-z0-9_-], so we use '_' as the key/value separator
--  and strip anything else from the value.)
--
-- Flow across nginx phases (driven by medisync_auth + nginx.conf on /wado/):
--   access      : medisync_auth.verify() stashes ngx.ctx.medisync_{is_stow,company,facility}
--   body_filter : capture_body() accumulates the (small) STOW JSON response
--   log         : schedule() parses StudyInstanceUID(s) and fires an async timer that
--                 calls Orthanc (/tools/lookup + PUT labels) over a cosocket.
-- Labeling is best-effort + async: the client already got its STOW 200; a label
-- failure is logged, never blocks the upload.

local _M = {}

local cjson = require "cjson.safe"

-- Orthanc base URL (same backend nginx proxies to). Generated into medisync_runtime
-- by docker-entrypoint.sh from ORTHANC_BACKEND_URL; fall back to the compose default.
local _ok_rt, _rt = pcall(require, "medisync_runtime")
local function backend()
  if _ok_rt and _rt and _rt.orthanc_backend and _rt.orthanc_backend ~= "" then
    return _rt.orthanc_backend
  end
  return "http://orthanc:8042"
end

local RESP_CAP = 1024 * 1024   -- never buffer more than 1MB of the STOW response

-- Keep only label-legal chars in a value.
local function sanitize(v)
  return (tostring(v or ""):gsub("[^%w%-_]", ""))
end

-- body_filter phase: accumulate the STOW response body (only when flagged a STOW).
function _M.capture_body()
  if not ngx.ctx.medisync_is_stow then return end
  if ngx.ctx.medisync_resp_len and ngx.ctx.medisync_resp_len >= RESP_CAP then return end
  local chunk = ngx.arg[1]
  if chunk and #chunk > 0 then
    local buf = ngx.ctx.medisync_resp_buf or {}
    buf[#buf + 1] = chunk
    ngx.ctx.medisync_resp_buf = buf
    ngx.ctx.medisync_resp_len = (ngx.ctx.medisync_resp_len or 0) + #chunk
  end
end

-- Timer body: lookup each StudyInstanceUID -> Orthanc id, then PUT the 2 labels.
local function do_label(premature, study_uids, company, facility)
  if premature then return end

  local labels = {}
  company  = sanitize(company)
  facility = sanitize(facility)
  if company  ~= "" then labels[#labels + 1] = "companyUuid_"  .. company  end
  if facility ~= "" then labels[#labels + 1] = "facilityUuid_" .. facility end
  if #labels == 0 then return end

  local http = require "resty.http"
  local base = backend()

  for _, uid in ipairs(study_uids) do
    local httpc = http.new()
    httpc:set_timeout(5000)

    -- StudyInstanceUID -> Orthanc study id
    local res, err = httpc:request_uri(base .. "/tools/lookup", {
      method = "POST", body = uid, headers = { ["Content-Type"] = "text/plain" },
    })
    if not res then
      ngx.log(ngx.WARN, "medisync_label: lookup ", uid, " failed: ", err or "?")
    elseif res.status ~= 200 then
      ngx.log(ngx.WARN, "medisync_label: lookup ", uid, " http=", res.status)
    else
      local arr = cjson.decode(res.body)
      local sid
      if type(arr) == "table" then
        for _, e in ipairs(arr) do
          if e.Type == "Study" and e.ID then sid = e.ID break end
        end
      end
      if not sid then
        ngx.log(ngx.WARN, "medisync_label: no Study resource for uid ", uid)
      else
        for _, lbl in ipairs(labels) do
          local r2 = httpc:request_uri(base .. "/studies/" .. sid .. "/labels/" .. lbl, {
            method = "PUT",
          })
          if not r2 then
            ngx.log(ngx.WARN, "medisync_label: PUT ", lbl, " on ", sid, " failed")
          elseif r2.status ~= 200 and r2.status ~= 201 then
            ngx.log(ngx.WARN, "medisync_label: PUT ", lbl, " on ", sid, " http=", r2.status)
          end
        end
        ngx.log(ngx.NOTICE, "medisync_label: labeled study ", sid, " uid=", uid,
          " company=", company, " facility=", facility)
      end
    end
  end
end

-- log phase: if this was a successful STOW, schedule the async labeling.
function _M.schedule()
  if not ngx.ctx.medisync_is_stow then return end
  if ngx.status ~= 200 then return end   -- STOW success only

  local company  = ngx.ctx.medisync_company
  local facility = ngx.ctx.medisync_facility
  if (not company or company == "") and (not facility or facility == "") then return end

  local body = table.concat(ngx.ctx.medisync_resp_buf or {})
  if body == "" then return end

  -- StudyInstanceUID(s) appear in the RetrieveURL(s): ".../studies/<uid>[/...]".
  local seen, uids = {}, {}
  for uid in body:gmatch("studies/([%d%.]+)") do
    if not seen[uid] then seen[uid] = true; uids[#uids + 1] = uid end
  end
  if #uids == 0 then
    ngx.log(ngx.WARN, "medisync_label: STOW 200 but no StudyInstanceUID in response")
    return
  end

  local ok, err = ngx.timer.at(0, do_label, uids, company, facility)
  if not ok then ngx.log(ngx.ERR, "medisync_label: ngx.timer.at failed: ", err) end
end

return _M
