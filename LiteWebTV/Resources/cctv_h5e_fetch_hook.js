;(function () {
    try {
        if (typeof window !== 'undefined') {
            window.__lwtvH5eWorkerPatched = 1;
        }
        function note(tag) {
            if (typeof window === 'undefined') return;
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + tag;
        }
        var LOCATION_HREF = 'blob:https://tv.cctv.com/5bca710b-9f02-41f0-a9f1-102bbc65192a';
        function spoofLocation(name) {
            if (name === 'self.location.host' || name === 'location.host') return '';
            if (name === 'self.location.protocol' || name === 'location.protocol') return 'blob:';
            if (name === 'self.location.href' || name === 'location.href') return LOCATION_HREF;
            return null;
        }
        function writeSpoof(text) {
            var n = lengthBytesUTF8(text) + 1;
            var ptr = _malloc(n);
            stringToUTF8(text, ptr, n);
            return ptr;
        }
        if (typeof _emscripten_asm_const_ii === 'function') {
            var origAsm = _emscripten_asm_const_ii;
            _emscripten_asm_const_ii = function (idx, arg) {
                try {
                    var name = UTF8ToString(arg);
                    var spoof = spoofLocation(name);
                    if (spoof !== null) {
                        if (name.indexOf('host') >= 0) note('|eh');
                        else if (name.indexOf('protocol') >= 0) note('|ep');
                        else note('|er');
                        return writeSpoof(spoof);
                    }
                    if (name && name.indexOf('location') >= 0) note('|ac:' + name);
                } catch (e) {}
                return origAsm.apply(this, arguments);
            };
        }
        var orig = _emscripten_start_fetch;
        _emscripten_start_fetch = function (fetchPtr, ok, err, prog, ready) {
            var url = '';
            try {
                var urlPtr = HEAPU32[fetchPtr + 8 >> 2];
                url = urlPtr ? UTF8ToString(urlPtr) : '';
            } catch (e) {}
            if (typeof window !== 'undefined') {
                window.__lwtvH5eLastFetch = (url || ('fetch:' + fetchPtr)) + '|q';
                /* NativeWasmTv 挂起每一次 env.q：InitPlayer 只发配置请求，
                 * 必须等它返回后再由 host 补 JSON，否则密钥永远进不来。 */
                window.__lwtvH5ePendingFetch = fetchPtr;
            }
            return fetchPtr;
        };
        void orig;
    } catch (err) {
        if (typeof window !== 'undefined') {
            window.__lwtvH5eWorkerPatchErr = String(err);
        }
    }
})();
