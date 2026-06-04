/**
 * Medisync PACS edge cache — Cloudflare Worker
 *
 * Sits in front of the Railway-hosted Orthanc (Singapore) and caches DICOM
 * responses at Cloudflare PoPs. VN clients hit the HCM/HAN PoP at local-ISP
 * bandwidth instead of paying VN<->SG RTT + bandwidth on every request.
 *
 * Three tiers:
 *   - IMMUTABLE (1-year)  GET /wado/studies/<UID>/series/<UID>/instances/<UID>
 *                         GET .../instances/<UID>/frames/<N>
 *                         GET /assets/* and any content-hashed OHIF bundle
 *                             (app.bundle.<hash>.js, <id>.bundle.<hash>.js, …)
 *       SOPInstanceUIDs are immutable by DICOM spec — pixel data never changes;
 *       OHIF bundles are content-hashed, so a change is always a new filename.
 *       Caching them lets the OHIF app boot from the VN PoP, not Railway SG.
 *   - STUDY META (10-min) GET /wado/studies/<UID>            (study-scoped:
 *                         GET .../studies/<UID>/metadata      metadata, series
 *                         GET .../studies/<UID>/series        list, instance
 *                         GET .../series/<UID>/metadata       list, etc.)
 *       Per-study metadata is immutable once a study finishes arriving, but a
 *       study still being acquired can change — so a short TTL caps staleness
 *       to 10 min while still killing the repeat-fetch cost (warmer + doctor +
 *       re-reads in a session all hit the cache).
 *   - BYPASS              GET /wado/studies?...   (QIDO — the study search
 *                         every non-GET            result set changes as new
 *                                                  studies are registered;
 *                                                  Orthanc DELETE must reach
 *                                                  origin).
 *
 * Responses are decorated with CORS + CORP headers so the OHIF page (a
 * different origin, loaded under COEP: require-corp) can fetch cross-origin.
 * X-LR-Cache: HIT | MISS | BYPASS is added for probing/observability.
 */

// Per-instance / per-frame pixel data — immutable by DICOM spec. Mirrors the
// regex location in ohif-nginx.conf.
const IMMUTABLE_RE =
  /^\/wado\/studies\/[^/]+\/series\/[^/]+\/instances\/[^/]+(?:\/frames\/[^/]+)?\/?$/;

// Anything scoped to one study UID — metadata, series list, instance list.
// Does NOT match the bare QIDO search `/wado/studies` (no UID segment).
const STUDY_META_RE = /^\/wado\/studies\/[^/]+(?:\/|$)/;

// OHIF app static assets safe to cache for 1 year:
//   - /assets/*  — icons / manifests, stable across builds.
//   - any file with a 16+ hex content-hash segment in its name — the webpack
//     bundles & web-workers: app.bundle.<hash>.js, <id>.bundle.<hash>.js,
//     index.worker.<hash>.worker.js. The build renames them on every change,
//     so the URL itself is the cache-buster.
// Deliberately NOT matched (stay BYPASS so a redeploy is picked up at once):
// index.html, app-config.js, init-service-worker.js, medisync-extras.js,
// medisync-toolbar.js, and OHIF's UN-hashed CSS (app.bundle.css, <id>.css).
const ASSET_RE = /^\/assets\//;
const HASHED_RE = /\.[0-9a-f]{16,}\./;

const IMMUTABLE_TTL = 'public, max-age=31536000, immutable';
const META_TTL = 'public, max-age=600'; // 10 min — caps metadata staleness

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Accept, Authorization',
    'Access-Control-Expose-Headers': '*',
    // COEP: require-corp on the OHIF page demands this on every subresource.
    'Cross-Origin-Resource-Policy': 'cross-origin',
  };
}

/**
 * Overwrite CORS/CORP headers (delete-then-set so we never emit a duplicate
 * header alongside the one the origin nginx already adds) and tag cache state.
 */
function decorate(resp, cacheState) {
  const h = new Headers(resp.headers);
  for (const [k, v] of Object.entries(corsHeaders())) {
    h.delete(k);
    h.set(k, v);
  }
  h.set('X-LR-Cache', cacheState);
  return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: h });
}

/**
 * Build a minimal forward-header set. Critically we DROP the inbound Host
 * header — Railway routes by Host, so forwarding `pacs.creanova.tech` would
 * loop the edge router. fetch() derives the correct Host from the target URL.
 */
function forwardHeaders(request) {
  const h = new Headers();
  const accept = request.headers.get('Accept');
  if (accept) h.set('Accept', accept);
  const enc = request.headers.get('Accept-Encoding');
  if (enc) h.set('Accept-Encoding', enc);
  const range = request.headers.get('Range');
  if (range) h.set('Range', range);
  return h;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const origin = (env.ORIGIN || '').replace(/\/$/, '');
    if (!origin) {
      return new Response('ORIGIN not configured', { status: 500 });
    }
    const originUrl = origin + url.pathname + url.search;

    // CORS preflight — answer at the edge, never round-trip to origin.
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    // Decide cache tier. WADO paths are matched first so a study UID that
    // happens to contain a 16-digit run can't fall through to HASHED_RE.
    // QIDO search and every non-GET fall through to bypass.
    let tier = 'bypass';
    if (request.method === 'GET') {
      const p = url.pathname;
      if (IMMUTABLE_RE.test(p)) tier = 'immutable';
      else if (STUDY_META_RE.test(p)) tier = 'meta';
      else if (ASSET_RE.test(p) || HASHED_RE.test(p)) tier = 'immutable';
    }

    // Pass-through: QIDO study search and every non-GET method.
    if (tier === 'bypass') {
      const resp = await fetch(originUrl, {
        method: request.method,
        headers: forwardHeaders(request),
        body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
      });
      return decorate(resp, 'BYPASS');
    }

    // Cacheable — PoP-local cache, keyed by the origin URL so the key is
    // stable regardless of which domain fronts the Worker.
    const ttl = tier === 'immutable' ? IMMUTABLE_TTL : META_TTL;
    const cache = caches.default;
    const cacheKey = new Request(originUrl, { method: 'GET' });

    const hit = await cache.match(cacheKey);
    if (hit) {
      return decorate(hit, 'HIT');
    }

    const originResp = await fetch(originUrl, {
      method: 'GET',
      headers: forwardHeaders(request),
    });

    // Only cache a clean success. Errors/redirects fall through uncached so a
    // transient origin blip never gets pinned.
    if (originResp.status === 200) {
      const h = new Headers(originResp.headers);
      h.set('Cache-Control', ttl);
      h.delete('Set-Cookie');
      const stored = new Response(originResp.body, {
        status: 200,
        statusText: originResp.statusText,
        headers: h,
      });
      ctx.waitUntil(cache.put(cacheKey, stored.clone()));
      return decorate(stored, 'MISS');
    }

    return decorate(originResp, 'MISS');
  },
};
