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
        /* emval 的属性读取必须返回 handle（整数），直接返回字符串会让
         * wasm 把字符串当 handle 解引用，InitPlayer 必抛 Cannot use deleted val。
         * 也绝不能改真实 location：给 location 赋值是页面导航。 */
        if (typeof __emval_get_property === 'function' && typeof __emval_register === 'function') {
            var origProp = __emval_get_property;
            var fakeLocation = {
                host: '',
                protocol: 'blob:',
                href: LOCATION_HREF,
                origin: 'null',
                toString: function () { return LOCATION_HREF; }
            };
            __emval_get_property = function (obj, prop) {
                var name = '';
                var target = null;
                try { name = requireHandle(prop); } catch (e) { name = ''; }
                try { target = requireHandle(obj); } catch (e) { target = null; }
                if (name === 'location' &&
                    (target === self || target === window || target === globalThis || target === document)) {
                    note('|vl');
                    return __emval_register(fakeLocation);
                }
                if (target === self.location || target === fakeLocation) {
                    if (name === 'host') { note('|vh'); return __emval_register(''); }
                    if (name === 'protocol') { note('|vp'); return __emval_register('blob:'); }
                    if (name === 'href') { note('|vr'); return __emval_register(LOCATION_HREF); }
                }
                return origProp.apply(this, arguments);
            };
        }
        if (typeof _emscripten_asm_const_ii === 'function') {
            var origAsm = _emscripten_asm_const_ii;
            _emscripten_asm_const_ii = function (idx, arg) {
                try {
                    var name = UTF8ToString(arg);
                    var spoof = null;
                    if (name === 'self.location.host' || name === 'location.host') { note('|eh'); spoof = ''; }
                    else if (name === 'self.location.protocol' || name === 'location.protocol') { note('|ep'); spoof = 'blob:'; }
                    else if (name === 'self.location.href' || name === 'location.href') { note('|er'); spoof = LOCATION_HREF; }
                    if (spoof !== null) {
                        var n = lengthBytesUTF8(spoof) + 1;
                        var ptr = _malloc(n);
                        stringToUTF8(spoof, ptr, n);
                        return ptr;
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
