;(function () {
    try {
        var orig = _emscripten_start_fetch;
        _emscripten_start_fetch = function (fetchPtr, ok, err, prog, ready) {
            var pending = null;
            try {
                var urlPtr = HEAPU32[fetchPtr + 8 >> 2];
                var url = urlPtr ? UTF8ToString(urlPtr) : '';
                if (typeof window !== 'undefined') {
                    window.__lwtvH5eLastFetch = url || ('fetch:' + fetchPtr);
                }
                if (url && url.toLowerCase().indexOf('h5player') >= 0) {
                    /* 只挂起：wasm 官方路径是异步回调，InitPlayer 还在栈上时
                     * 同步触发 onsuccess 会重入 wasm 破坏其内部状态。
                     * host JS 在 InitPlayer 返回后调用 __lwtvH5eCompleteFetch。 */
                    pending = fetchPtr;
                }
            } catch (e) {
                if (typeof window !== 'undefined') {
                    window.__lwtvH5eLastFetch = 'patch-err:' + e;
                }
            }
            if (pending !== null) {
                if (typeof window !== 'undefined') {
                    window.__lwtvH5ePendingFetch = pending;
                }
                return pending;
            }
            return orig.apply(this, arguments);
        };
    } catch (err) {}
})();
