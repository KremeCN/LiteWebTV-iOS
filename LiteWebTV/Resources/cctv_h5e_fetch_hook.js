;(function () {
    try {
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
            if (url && url.toLowerCase().indexOf('h5player') >= 0) {
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
    } catch (err) {}
})();
