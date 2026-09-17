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
        var origRegister = typeof __emval_register === 'function' ? __emval_register : null;
        function tagValue(v, seen) {
            try {
                if (!v || typeof v !== 'object') return v;
                if (seen.indexOf(v) >= 0) return v;
                seen.push(v);
                if (typeof v.host === 'string') v.host = '';
                if (typeof v.protocol === 'string') v.protocol = 'blob:';
                if (typeof v.href === 'string') v.href = LOCATION_HREF;
                if (typeof v.location === 'object' && v.location) tagValue(v.location, seen);
                if (typeof v.self === 'object' && v.self) tagValue(v.self, seen);
            } catch (e) {}
            return v;
        }
        if (origRegister) {
            __emval_register = function (value) {
                var handle = origRegister.apply(this, arguments);
                try {
                    var v = value;
                    if (v && typeof v === 'object' &&
                        (typeof v.host === 'string' || typeof v.protocol === 'string' ||
                         typeof v.href === 'string' || typeof v.location === 'object')) {
                        note('|vg');
                        tagValue(v, []);
                    }
                } catch (e) {}
                return handle;
            };
        }
        if (typeof __emval_get_property === 'function') {
            var origProp = __emval_get_property;
            __emval_get_property = function (obj, prop) {
                var v = null;
                try {
                    var name = requireHandle(prop);
                    if (name === 'location') note('|vl');
                    else if (name === 'host') note('|vh');
                    else if (name === 'protocol') note('|vp');
                    else if (name === 'href') note('|vr');
                    v = origProp.apply(this, arguments);
                    if (name === 'host') v = '';
                    else if (name === 'protocol') v = 'blob:';
                    else if (name === 'href') v = LOCATION_HREF;
                } catch (e) {}
                return v;
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
