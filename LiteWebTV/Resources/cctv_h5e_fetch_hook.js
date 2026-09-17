;(function () {
    try {
        var orig = _emscripten_start_fetch;
        _emscripten_start_fetch = function (fetchPtr, ok, err, prog, ready) {
            try {
                var urlPtr = HEAPU32[fetchPtr + 8 >> 2];
                var url = urlPtr ? UTF8ToString(urlPtr) : '';
                if (typeof window !== 'undefined') {
                    window.__lwtvH5eLastFetch = url || ('fetch:' + fetchPtr);
                }
                if (url && url.toLowerCase().indexOf('h5player') >= 0) {
                    var json = '{"h5player":{"ver":20190904,"md5":"c7ed5a71dbe4dee1a2ba171f660ee98d","BTime":"2019-09-04-20:25:10"}}';
                    var n = lengthBytesUTF8(json);
                    var dataPtr = _malloc(n + 1);
                    stringToUTF8(json, dataPtr, n + 1);
                    HEAPU32[fetchPtr + 12 >> 2] = dataPtr;
                    Fetch.setu64(fetchPtr + 16, n);
                    Fetch.setu64(fetchPtr + 24, 0);
                    Fetch.setu64(fetchPtr + 32, n);
                    HEAPU16[fetchPtr + 40 >> 1] = 4;
                    HEAPU16[fetchPtr + 42 >> 1] = 200;
                    stringToUTF8('OK', fetchPtr + 44, 64);
                    var onsuccess = HEAPU32[fetchPtr + 148 >> 2];
                    var onready = HEAPU32[fetchPtr + 160 >> 2];
                    if (onsuccess) dynCall_vi(onsuccess, fetchPtr);
                    if (onready) dynCall_vi(onready, fetchPtr);
                    if (typeof window !== 'undefined') window.__lwtvH5eConfigLoaded = true;
                    return fetchPtr;
                }
            } catch (e) {
                if (typeof window !== 'undefined') {
                    window.__lwtvH5eLastFetch = 'patch-err:' + e;
                }
            }
            return orig.apply(this, arguments);
        };
    } catch (err) {}
})();
