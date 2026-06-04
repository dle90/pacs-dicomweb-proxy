#!/usr/bin/env node
// mint-view-token.mjs — mint a Medisync PACS view-token (RS256) for the dicomweb-proxy.
//
// The proxy read-auth (auth/lua/medisync_auth.lua) accepts this as
// `Authorization: Bearer <jwt>` on /wado/* and binds it to a study:
//   • --study <UID>  → token scoped to that ONE study (production shape).
//   • (omitted)      → MASTER token: studyUid=null → ANY study + list-all. Use this to
//                      test the viewer locally WITHOUT the full HIS-RIS issue flow.
//
// Dependency-free (Node built-ins only). Usage:
//   node mint-view-token.mjs --key <private_key_pkcs8.pem> [--study <UID>] \
//        [--iss HIS] [--aud PACS-VIEWER] [--sub tester] [--uuid u-1] [--ttl 30]
//
// Open the viewer with the token in the URL HASH (never logged server-side):
//   http://localhost:3000/?StudyInstanceUIDs=<UID>#token=<paste jwt>
import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';

const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith('--')) args[a.slice(2)] = process.argv[++i];
}
if (!args.key) {
  console.error('ERROR: --key <private_key_pkcs8.pem> is required');
  process.exit(1);
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/=+$/g, '').replace(/\+/g, '-').replace(/\//g, '_');

const now = Math.floor(Date.now() / 1000);
const ttlMin = Number(args.ttl ?? 30);
const payload = {
  iss: args.iss ?? 'HIS',
  aud: args.aud ?? 'PACS-VIEWER',
  sub: args.sub ?? 'tester',
  uuid: args.uuid ?? 'u-test',
  // studyUid present → scoped to that study; null → MASTER (any study + list-all).
  studyUid: args.study ?? null,
  iat: now,
  exp: now + ttlMin * 60,
};
const header = { alg: 'RS256', typ: 'JWT' };
const signingInput = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload));
const sig = createSign('RSA-SHA256').update(signingInput).end().sign(readFileSync(args.key));
process.stdout.write(signingInput + '.' + b64url(sig) + '\n');
