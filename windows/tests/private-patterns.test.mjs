import{test}from'node:test';
import assert from'node:assert/strict';
import{sensitive}from'../scripts/private-patterns.mjs';
import{PORTABLE_COLOR_BASE64}from'../packages/comp-bridge/portable-color-wasm.mjs';
const flagged=text=>sensitive.some(pattern=>pattern.test(text));
test('source and package review recognize canonical credentials without folding Base64 character case',()=>{
  for(const prefix of ['AKIA','ASIA']){assert.equal(flagged(prefix+'A'.repeat(16)),true);assert.equal(flagged(prefix+'b'.repeat(16)),false);}
  for(const [prefix,length]of [['ghp_',30],['github_pat_',40],['sk-',32],['xoxb-',24],['AIza',35]])assert.equal(flagged(prefix+'a'.repeat(length)),true);
  for(const key of ['api_key','password','aws_secret_access_key','aws_session_token']){assert.equal(flagged(key+'="'+'a'.repeat(32)+'"'),true);assert.equal(flagged(JSON.stringify({[key]:('a+/=').repeat(8)})),true);}
  assert.equal(flagged(PORTABLE_COLOR_BASE64),false);assert.equal(flagged(PORTABLE_COLOR_BASE64+';const password="'+'a'.repeat(32)+'"'),true);
  assert.equal(flagged('/'+['home','sample','private','file'].join('/')),true);assert.equal(flagged(['C:','Users','sample','private'].join('\\')),true);
});
