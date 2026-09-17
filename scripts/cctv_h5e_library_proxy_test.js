const assert = require('assert');

function rewrite(url, origin = 'http://127.0.0.1:4321') {
    const u = new URL(String(url), origin + '/h5e.html');
    const path = u.pathname;
    if (path.startsWith('/Library/') || path.startsWith('/library/')) {
        return origin + path + u.search;
    }
    return url;
}

assert.strictEqual(
    rewrite('/Library/H5player.json'),
    'http://127.0.0.1:4321/Library/H5player.json'
);
assert.strictEqual(
    rewrite('https://tv.cctv.com/Library/H5player.json'),
    'http://127.0.0.1:4321/Library/H5player.json'
);
assert.strictEqual(
    rewrite('https://js.player.cntv.cn/creator/live.worker.js'),
    'https://js.player.cntv.cn/creator/live.worker.js'
);

function isLibraryPath(path) {
    return path.toLowerCase().startsWith('/library/');
}

assert.ok(isLibraryPath('/Library/H5player.json'));
assert.ok(isLibraryPath('/library/ios.cdrm.sw.base.js'));
assert.ok(!isLibraryPath('/h5e.js'));

console.log('cctv_h5e_library_proxy tests passed');
