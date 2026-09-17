;(function () {
    try {
        if (typeof window !== 'undefined') {
            window.__lwtvH5eWorkerPatched = 1;
        }
        function note(tag) {
            if (typeof window === 'undefined') return;
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + tag;
        }
        if (typeof _emscripten_asm_const_ii === 'function') {
            var origAsm = _emscripten_asm_const_ii;
            _emscripten_asm_const_ii = function (idx, arg) {
                try {
                    var name = UTF8ToString(arg);
                    if (name === 'self.location.host' || name === 'location.host') note('|eh');
                    else if (name === 'self.location.protocol' || name === 'location.protocol') note('|ep');
                    else if (name === 'self.location.href' || name === 'location.href') note('|er');
                    else if (name && name.indexOf('location') >= 0) note('|ac:' + name);
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
                window.__lwtvH5eLastFetch = url || ('fetch:' + fetchPtr);
            }
            if (url && /h5player|\/library\/|^blob:/i.test(url)) {
                /* 挂起所有 H5player 配置请求（XHR 与 IDB 缓存路径都拦在前面）：
                 * wasm 官方语义是异步回调，InitPlayer 还在栈上时同步触发会重入 wasm。
                 * host JS 在 InitPlayer 返回后调用 completePendingFetch 补响应。 */
                if (typeof window !== 'undefined') {
                    window.__lwtvH5ePendingFetch = fetchPtr;
                }
                return fetchPtr;
            }
            return orig.apply(this, arguments);
        };
    } catch (err) {
        if (typeof window !== 'undefined') {
            window.__lwtvH5eWorkerPatchErr = String(err);
        }
    }
})();
