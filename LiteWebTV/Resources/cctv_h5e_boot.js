(function () {
    'use strict';

    var H5PLAYER_JSON = '{"h5player":{"ver":20190904,"md5":"c7ed5a71dbe4dee1a2ba171f660ee98d","BTime":"2019-09-04-20:25:10"}}';

    window.__lwtvH5eBoot = 1;
    window.__lwtvH5eWrap = 0;
    window.__lwtvH5eConfigLoaded = window.__lwtvH5eConfigLoaded || false;
    window.__lwtvH5eLastFetch = window.__lwtvH5eLastFetch || 'boot';
    window.__lwtvH5eModule = window.__lwtvH5eModule || null;

    function markConfig() {
        window.__lwtvH5eConfigLoaded = true;
    }

    function isConfigURL(url) {
        var text = String(url || '').toLowerCase();
        return text.indexOf('h5player') >= 0 || text.indexOf('/library/') >= 0 || text.indexOf('blob:') === 0;
    }

    function rewrite(url) {
        try {
            var parsed = new URL(String(url), location.href);
            var path = parsed.pathname;
            if (path.indexOf('/Library/') === 0 || path.indexOf('/library/') === 0) {
                return location.origin + path + parsed.search;
            }
        } catch (err) {}
        return url;
    }

    var LOCATION_HREF = 'blob:https://tv.cctv.com/5bca710b-9f02-41f0-a9f1-102bbc65192a';
    var origEval = window.eval;
    window.eval = function (code) {
        // worker 的 _emscripten_asm_const_ii 会走 eval(name)。这里与 NativeWasmTv env.y 对齐。
        var text = String(code || '');
        if (text === 'self.location.host' || text === 'location.host') {
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + '|eh';
            return '';
        }
        if (text === 'self.location.protocol' || text === 'location.protocol') {
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + '|ep';
            return 'blob:';
        }
        if (text === 'self.location.href' || text === 'location.href') {
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + '|er';
            return LOCATION_HREF;
        }
        if (text.indexOf('location') >= 0) {
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + '|ev:' + text.replace(/\s+/g, '');
        }
        return origEval(code);
    };

    function seedIDB() {
        if (!window.indexedDB) return;
        try {
            var req = indexedDB.open('emscripten_filesystem', 1);
            req.onupgradeneeded = function (event) {
                var db = event.target.result;
                if (!db.objectStoreNames.contains('FILES')) db.createObjectStore('FILES');
            };
            req.onsuccess = function (event) {
                var db = event.target.result;
                if (!db.objectStoreNames.contains('FILES')) return;
                var payload = new TextEncoder().encode(H5PLAYER_JSON);
                var tx = db.transaction('FILES', 'readwrite');
                var store = tx.objectStore('FILES');
                [
                    'https://tv.cctv.com/Library/H5player.json',
                    'http://tv.cctv.com/Library/H5player.json',
                    location.origin + '/Library/H5player.json',
                    '/Library/H5player.json',
                    'H5player.json',
                    'blob:///Library/H5player.json',
                    'blob://Library/H5player.json'
                ].forEach(function (key) {
                    try { store.put(payload, key); } catch (err) {}
                });
            };
        } catch (err) {}
    }
    seedIDB();

    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
        var next = typeof url === 'string' ? rewrite(url) : url;
        arguments[1] = next;
        window.__lwtvH5eLastFetch = String(next);
        if (isConfigURL(next)) {
            this.addEventListener('loadend', function () {
                if (this.status === 0 || (this.status >= 200 && this.status < 300)) markConfig();
            });
        }
        return origOpen.apply(this, arguments);
    };

    function readCString(memory, ptr) {
        if (!memory || !ptr) return '';
        var bytes = new Uint8Array(memory.buffer);
        var end = ptr;
        while (end < bytes.length && bytes[end] !== 0) end++;
        return new TextDecoder().decode(bytes.subarray(ptr, end));
    }

    function writeCString(heap, ptr, text, max) {
        var i;
        var n = Math.min(text.length, max - 1);
        for (i = 0; i < n; i++) heap[ptr + i] = text.charCodeAt(i);
        heap[ptr + n] = 0;
    }

    function invokeCallback(env, Module, index, ptr) {
        if (!index) return;
        try {
            var fn = env.table && env.table.get(index);
            if (typeof fn === 'function') {
                fn(ptr);
                return;
            }
        } catch (err) {}
        if (typeof Module.dynCall_vi === 'function') {
            try { Module.dynCall_vi(index, ptr); } catch (err) {}
        }
    }

    function completeH5playerFetch(env, ptr) {
        var Module = window.__lwtvH5eModule;
        if (!Module || typeof Module._malloc !== 'function' || !Module.HEAPU8) {
            window.__lwtvH5eLastFetch += '|no-module';
            return false;
        }
        var payload = new TextEncoder().encode(H5PLAYER_JSON);
        var dataPtr = Module._malloc(payload.length);
        Module.HEAPU8.set(payload, dataPtr);
        var heap32 = Module.HEAPU32;
        var heap16 = Module.HEAPU16;
        heap32[(ptr + 12) >> 2] = dataPtr;
        heap32[(ptr + 16) >> 2] = payload.length;
        heap32[(ptr + 20) >> 2] = 0;
        heap32[(ptr + 24) >> 2] = 0;
        heap32[(ptr + 28) >> 2] = 0;
        heap32[(ptr + 32) >> 2] = payload.length;
        heap32[(ptr + 36) >> 2] = 0;
        heap16[(ptr + 40) >> 1] = 4;
        heap16[(ptr + 42) >> 1] = 200;
        writeCString(Module.HEAPU8, ptr + 44, 'OK', 64);
        invokeCallback(env, Module, heap32[(ptr + 148) >> 2], ptr);
        invokeCallback(env, Module, heap32[(ptr + 160) >> 2], ptr);
        markConfig();
        return true;
    }

    function wrapEnv(env) {
        if (!env || env.__lwtvWrapped) return;
        env.__lwtvWrapped = true;
        var orig = env.q;
        window.__lwtvH5eWrap = typeof orig === 'function' ? 1 : 0;
        if (typeof orig !== 'function') {
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + '|no-q';
            return;
        }
        env.q = function (ptr) {
            var url = '';
            try {
                var heap32 = new Uint32Array(env.memory.buffer);
                url = readCString(env.memory, heap32[(ptr + 8) >> 2]);
            } catch (err) {
                url = 'q-read-err';
            }
            window.__lwtvH5eLastFetch = (url || ('q:' + ptr)) + '|q';
            window.__lwtvH5ePendingFetch = ptr;
            return ptr;
        };
    }

    var origInstantiate = WebAssembly.instantiate.bind(WebAssembly);
    WebAssembly.instantiate = function (buffer, imports) {
        if (imports && imports.env) wrapEnv(imports.env);
        return origInstantiate(buffer, imports);
    };
    if (WebAssembly.instantiateStreaming) {
        var origStreaming = WebAssembly.instantiateStreaming.bind(WebAssembly);
        WebAssembly.instantiateStreaming = function (source, imports) {
            if (imports && imports.env) wrapEnv(imports.env);
            return origStreaming(source, imports);
        };
    }
})();
