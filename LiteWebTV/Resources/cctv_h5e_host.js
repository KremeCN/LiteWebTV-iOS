(function () {
    'use strict';

    var PAGE_HOST = 'https://tv.cctv.com';
    var MEDIA_TAG = 'player_container_player';
    var MEMORY_EXTEND = 2048;
    var VIDEO_PID = 0x100;
    var moduleInstance = null;
    var ready = false;
    var sessionBegin = false;
    var shouldDecrypt = false;
    var vmpTag = '';
    var originNow = Date.now.bind(Date);

    function waitForModule(done) {
        if (typeof CNTVModule !== 'function') {
            setTimeout(function () { waitForModule(done); }, 50);
            return;
        }
        var instance = CNTVModule();
        if (typeof instance === 'function' && typeof instance._CNTV_InitPlayer !== 'function') {
            instance = instance();
        }
        moduleInstance = instance;
        function markReady() {
            if (ready) return;
            ready = true;
            done(null);
        }
        if (moduleInstance && typeof moduleInstance.then === 'function') {
            moduleInstance.then(markReady);
            return;
        }
        if (moduleInstance && (moduleInstance._CNTV_InitPlayer || moduleInstance.calledRun)) {
            markReady();
            return;
        }
        var prev = moduleInstance && moduleInstance.onRuntimeInitialized;
        if (moduleInstance) {
            moduleInstance.onRuntimeInitialized = function () {
                if (typeof prev === 'function') prev();
                markReady();
            };
        }
    }

    function allocTag(tag) {
        var memory = moduleInstance._jsmalloc(tag.length + MEMORY_EXTEND);
        moduleInstance.HEAP8.fill(0, memory, memory + tag.length + MEMORY_EXTEND);
        var i;
        for (i = 0; i < tag.length; i++) {
            moduleInstance.HEAP8[memory + i] = tag.charCodeAt(i);
        }
        return memory;
    }

    function initPlayer() {
        var memory = allocTag(MEDIA_TAG);
        var ret = moduleInstance._CNTV_InitPlayer(memory);
        moduleInstance._jsfree(memory);
        return ret;
    }

    function uninitPlayer() {
        var memory = allocTag(MEDIA_TAG);
        var ret = moduleInstance._CNTV_UnInitPlayer(memory);
        moduleInstance._jsfree(memory);
        return ret;
    }

    function updatePlayer() {
        var memory = allocTag(MEDIA_TAG);
        vmpTag = moduleInstance._CNTV_UpdatePlayer(memory).toString(16).padStart(8, '0');
        moduleInstance._jsfree(memory);
    }

    function decryptNAL(header, payload) {
        updatePlayer();
        var type = header & 0x1f;
        var special = true;
        if (type === 25) {
            shouldDecrypt = payload[0] === 1;
            special = false;
        } else if (type === 1 || type === 5) {
            if (!shouldDecrypt) return null;
        } else {
            return null;
        }

        var localTag = special ? (MEDIA_TAG + '##1000000##0') : MEDIA_TAG;
        var addr = moduleInstance._jsmalloc(payload.byteLength + 1 + MEMORY_EXTEND);
        var addr2 = moduleInstance._jsmalloc(localTag.length + 1);
        var heap = moduleInstance.HEAPU8 || moduleInstance.HEAP8;
        heap[addr] = header;
        heap.set(payload, addr + 1);
        var hostOff = addr + payload.byteLength + 1;
        var hi;
        for (hi = 0; hi < PAGE_HOST.length; hi++) {
            heap[hostOff + hi] = PAGE_HOST.charCodeAt(hi);
        }
        for (hi = 0; hi < localTag.length; hi++) {
            heap[addr2 + hi] = localTag.charCodeAt(hi);
        }

        var i;
        for (i = 0; i < vmpTag.length; i++) {
            if ('0123456'.indexOf(vmpTag[i]) >= 0) {
                var fn = moduleInstance['_CNTV_jsdecVOD' + (7 - i)];
                if (typeof fn === 'function') {
                    fn(addr2, addr, payload.byteLength + 1, PAGE_HOST.length);
                }
            }
        }
        var decryptedLength = moduleInstance._CNTV_jsdecVOD8(
            addr2,
            addr,
            payload.byteLength + 1,
            PAGE_HOST.length
        );
        var heapOut = moduleInstance.HEAPU8 || moduleInstance.HEAP8;
        var out = Uint8Array.from(heapOut.subarray(addr, addr + decryptedLength));
        moduleInstance._jsfree(addr);
        moduleInstance._jsfree(addr2);
        return out;
    }

    function findStartCodes(data) {
        var starts = [];
        var i = 0;
        while (i < data.length - 3) {
            if (data[i] === 0 && data[i + 1] === 0) {
                if (data[i + 2] === 1) {
                    starts.push({ code: 3, nal: i + 3 });
                    i += 3;
                    continue;
                }
                if (data[i + 2] === 0 && data[i + 3] === 1) {
                    starts.push({ code: 4, nal: i + 4 });
                    i += 4;
                    continue;
                }
            }
            i++;
        }
        return starts;
    }

    function decryptPES(data, map, ts) {
        var starts = findStartCodes(data);
        var n;
        for (n = 0; n < starts.length; n++) {
            var from = starts[n].nal;
            var to = n + 1 < starts.length ? starts[n + 1].nal - starts[n + 1].code : data.length;
            if (from >= to) continue;
            var header = data[from];
            var payload = data.subarray(from + 1, to);
            var decrypted;
            try {
                decrypted = decryptNAL(header, payload);
            } catch (err) {
                throw err;
            }
            if (!decrypted) continue;
            if (decrypted.length !== (to - from)) {
                throw new Error('nal-size');
            }
            var offset;
            for (offset = 0; offset < decrypted.length; offset++) {
                ts[map[from + offset]] = decrypted[offset];
            }
        }
    }

    function decryptTS(buffer) {
        var ts = new Uint8Array(buffer);
        if (ts.length < 188 || ts[0] !== 0x47) {
            return ts;
        }
        var pes = [];
        var map = [];
        function flush() {
            if (!pes.length) return;
            decryptPES(Uint8Array.from(pes), map, ts);
            pes = [];
            map = [];
        }
        var packet;
        for (packet = 0; packet + 188 <= ts.length; packet += 188) {
            if (ts[packet] !== 0x47) continue;
            var pid = ((ts[packet + 1] & 0x1f) << 8) | ts[packet + 2];
            var start = (ts[packet + 1] & 0x40) !== 0;
            var adaptation = (ts[packet + 3] >> 4) & 0x3;
            var payloadOff = 4;
            if (adaptation === 2 || adaptation === 3) {
                payloadOff = 5 + ts[packet + 4];
            }
            if (pid !== VIDEO_PID || payloadOff >= 188) continue;
            if (start) flush();
            var cursor = packet + payloadOff;
            var end = packet + 188;
            if (start && end - cursor >= 9 && ts[cursor] === 0 && ts[cursor + 1] === 0 && ts[cursor + 2] === 1) {
                cursor += 9 + ts[cursor + 8];
            }
            for (; cursor < end; cursor++) {
                pes.push(ts[cursor]);
                map.push(cursor);
            }
        }
        flush();
        return ts;
    }

    function startSession() {
        if (!ready) throw new Error('wasm-not-ready');
        if (sessionBegin) {
            uninitPlayer();
            sessionBegin = false;
        }
        shouldDecrypt = false;
        vmpTag = '';
        initPlayer();
        sessionBegin = true;
    }

    function stopSession() {
        if (!sessionBegin) return;
        try { uninitPlayer(); } catch (err) {}
        sessionBegin = false;
        shouldDecrypt = false;
    }

    window.__lwtvH5e = {
        isReady: function () { return ready && typeof CNTVModule === 'function'; },
        start: function () {
            startSession();
            return 'ok';
        },
        stop: function () {
            stopSession();
            return 'ok';
        },
        decryptInbox: function (id) {
            if (!ready || !sessionBegin) return Promise.resolve('not-ready');
            var frozen = originNow();
            Date.now = function () { return frozen; };
            var url = 'http://127.0.0.1:' + (window.__lwtvH5ePort || location.port) + '/inbox/' + id;
            return fetch(url).then(function (res) {
                if (!res.ok) throw new Error('inbox');
                return res.arrayBuffer();
            }).then(function (buf) {
                var out = decryptTS(buf);
                return fetch('http://127.0.0.1:' + (window.__lwtvH5ePort || location.port) + '/outbox/' + id, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/octet-stream' },
                    body: out
                });
            }).then(function (res) {
                Date.now = originNow;
                return res.ok ? 'ok' : 'put';
            }).catch(function (err) {
                Date.now = originNow;
                try { stopSession(); startSession(); } catch (resetErr) {}
                return 'drop:' + String(err && err.message ? err.message : err);
            });
        }
    };

    waitForModule(function () {});
})();
