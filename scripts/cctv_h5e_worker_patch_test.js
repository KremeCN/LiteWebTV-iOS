const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const hookPath = path.join(__dirname, '..', 'LiteWebTV', 'Resources', 'cctv_h5e_fetch_hook.js');
const hook = fs.readFileSync(hookPath, 'utf8');

assert.ok(!hook.includes('</script>'), 'fetch hook must be inline-safe');
assert.ok(hook.includes('_emscripten_start_fetch'), 'hook wraps start_fetch');
assert.ok(hook.includes('h5player'), 'hook recognizes H5player.json');

function patchLiveWorker(source, hookText) {
    const needle = 'var asmGlobalArg={}';
    const at = source.indexOf(needle);
    if (at < 0) return source;
    return source.slice(0, at) + hookText + source.slice(at);
}

const fixture = [
    'function UTF8ToString(A){return String(A);}',
    'function _emscripten_start_fetch(A){return A;}',
    'var Fetch={setu64:function(){}};',
    'var asmGlobalArg={},asmLibraryArg={$:abort,q:_emscripten_start_fetch},asm=Module.asm(asmGlobalArg,asmLibraryArg,buffer);'
].join('');

const patched = patchLiveWorker(fixture, hook);
assert.ok(patched.indexOf('var asmGlobalArg={}') > patched.indexOf('_emscripten_start_fetch = function'));
assert.ok(patched.includes('asmLibraryArg={$:abort,q:_emscripten_start_fetch}'));
assert.ok(!/var asmGlobalArg=\{\},\(function/.test(patched));

const checked = spawnSync('node', ['--check'], { input: patched, encoding: 'utf8' });
assert.strictEqual(checked.status, 0, checked.stderr);

console.log('cctv_h5e_worker_patch tests passed');
