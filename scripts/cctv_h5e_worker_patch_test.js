const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const hookPath = path.join(__dirname, '..', 'LiteWebTV', 'Resources', 'cctv_h5e_fetch_hook.js');
const hook = fs.readFileSync(hookPath, 'utf8');

assert.ok(!hook.includes('</script>'), 'fetch hook must be inline-safe');
assert.ok(hook.includes('_emscripten_start_fetch'), 'hook wraps start_fetch');
assert.ok(hook.includes('__lwtvH5ePendingFetch'), 'hook queues emscripten fetch');
assert.ok(hook.includes('__lwtvH5eWorkerPatched'), 'hook marks patched state');

assert.ok(hook.includes('_emscripten_asm_const_ii'), 'hook wraps asm_const location eval');
assert.ok(hook.includes('blob:'), 'hook spoofs blob location for InitPlayer');

function patchLiveWorker(source, hookText) {
    const needle = 'var asmGlobalArg={}';
    const at = source.indexOf(needle);
    if (at < 0) return source;
    // mirror the Swift fix: UTF-8 hook bytes mapped through latin1 so the
    // isoLatin1 round-trip cannot drop multibyte characters
    const latinHook = Buffer.from(hookText, 'utf8').toString('latin1');
    return source.slice(0, at) + latinHook + source.slice(at);
}

const fixture = [
    'function UTF8ToString(A){return String(A);}',
    'function _emscripten_start_fetch(A){return A;}',
    'function _emscripten_asm_const_ii(A,e){return e;}',
    'var Fetch={setu64:function(){}};',
    'var asmGlobalArg={},asmLibraryArg={$:abort,q:_emscripten_start_fetch,y:_emscripten_asm_const_ii},asm=Module.asm(asmGlobalArg,asmLibraryArg,buffer);'
].join('');

const patched = patchLiveWorker(fixture, hook);
assert.ok(patched.indexOf('var asmGlobalArg={}') > patched.indexOf('_emscripten_start_fetch = function'));
assert.ok(patched.includes('asmLibraryArg={$:abort,q:_emscripten_start_fetch,y:_emscripten_asm_const_ii}'));
assert.ok(!/var asmGlobalArg=\{\},\(function/.test(patched));
assert.notStrictEqual(patched, fixture, 'patched output must differ from input');

// guard: a missing hook must NOT produce a "patched" worker identical to upstream
const missingPatch = patchLiveWorker(fixture, '');
assert.strictEqual(missingPatch, fixture, 'empty hook must be a no-op so callers can detect failure');
const markerPatch = patchLiveWorker(fixture, '\n/* lwtv-fetch-hook-missing */\n');
assert.notStrictEqual(markerPatch, fixture, 'marker hook must still change the bytes');

// CJK comment must survive the latin1 byte mapping (the regression that shipped
// an unpatched worker silently: isoLatin1 cannot hold multibyte UTF-8)
const cjkPatch = patchLiveWorker(fixture, '/* 挂起所有 H5player 配置请求 */');
assert.notStrictEqual(cjkPatch, fixture, 'hook with CJK comment must still be injected');
assert.ok(cjkPatch.includes('/* '));
const checkedCjk = spawnSync('node', ['--check'], { input: cjkPatch, encoding: 'utf8' });
assert.strictEqual(checkedCjk.status, 0, checkedCjk.stderr);

const checked = spawnSync('node', ['--check'], { input: patched, encoding: 'utf8' });
assert.strictEqual(checked.status, 0, checked.stderr);

console.log('cctv_h5e_worker_patch tests passed');
