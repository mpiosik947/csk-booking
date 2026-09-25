// Read-only operator aid. This script never grants authority or calls the DB.
// Raw TXT values come from environment, never command-line arguments or output.
import { resolveTxt } from 'node:dns/promises';
import { timingSafeEqual } from 'node:crypto';
import { normalizeHostname } from '../lib/platform-domain.ts';

const host=normalizeHostname(process.env.DOMAIN_HOST);
const value=process.env.DOMAIN_TXT_VALUE;
if(!host || !/^[a-f0-9]{64}$/.test(value??'')) throw Error('INVALID_DOMAIN_OR_CHALLENGE');
const records=await resolveTxt(`_strzelajtu-verification.${host}`);
const expected=Buffer.from(value);
const matches=records.map(parts=>Buffer.from(parts.join(''))).filter(record=>record.length===expected.length&&timingSafeEqual(record,expected));
if(matches.length!==1) throw Error('DNS_TXT_MATCH_REQUIRED');
console.log('DNS_TXT=PASS; DB_WRITE=NO; PROVIDER_PROJECT_AND_TLS_REVIEW_STILL_REQUIRED');
