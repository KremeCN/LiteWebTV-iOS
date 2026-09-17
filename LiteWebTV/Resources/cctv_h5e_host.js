(function () {
    'use strict';

    var PAGE_HOST = 'https://tv.cctv.com';
    // NativeWasmTv / 官网直播播放器的 media tag，是 H5E 密钥状态的一部分。
    var MEDIA_TAG = 'h5player_player';
    var MEMORY_EXTEND = 2048;
    var moduleInstance = null;
    var ready = false;
    var sessionBegin = false;
    var shouldDecrypt = true;
    var vmpTag = '';
    var playerArg = 0;
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

    function heap() {
        return moduleInstance.HEAPU8 || moduleInstance.HEAP8;
    }

    function allocTag(tag) {
        var memory = moduleInstance._jsmalloc(tag.length + MEMORY_EXTEND);
        heap().fill(0, memory, memory + tag.length + MEMORY_EXTEND);
        var i;
        for (i = 0; i < tag.length; i++) {
            heap()[memory + i] = tag.charCodeAt(i);
        }
        return memory;
    }

    function ensurePlayerArg() {
        if (playerArg) return playerArg;
        playerArg = allocTag(MEDIA_TAG);
        return playerArg;
    }

    function releasePlayerArg() {
        if (!playerArg || !moduleInstance) {
            playerArg = 0;
            return;
        }
        try { moduleInstance._jsfree(playerArg); } catch (err) {}
        playerArg = 0;
    }

    function decryptFn(index) {
        var live = moduleInstance['_CNTV_jsdecLive' + index];
        if (typeof live === 'function') return live;
        return moduleInstance['_CNTV_jsdecVOD' + index];
    }

    function initPlayer() {
        ensurePlayerArg();
        return moduleInstance._CNTV_InitPlayer(playerArg);
    }

    function uninitPlayer() {
        if (!playerArg) return 0;
        return moduleInstance._CNTV_UnInitPlayer(playerArg);
    }

    function updatePlayer() {
        var raw = moduleInstance._CNTV_UpdatePlayer(playerArg);
        vmpTag = (raw >>> 0).toString(16).padStart(8, '0');
    }

    function decryptNAL(nal) {
        var header = nal[0];
        var type = header & 0x1f;
        if (type === 25) {
            shouldDecrypt = nal.length > 1 && nal[1] === 1;
        } else if (type === 1 || type === 5) {
            if (!shouldDecrypt) return null;
        } else {
            return null;
        }

        updatePlayer();
        var addr = moduleInstance._jsmalloc(nal.byteLength + PAGE_HOST.length + MEMORY_EXTEND);
        var mem = heap();
        mem.set(nal, addr);
        var hi;
        for (hi = 0; hi < PAGE_HOST.length; hi++) {
            mem[addr + nal.byteLength + hi] = PAGE_HOST.charCodeAt(hi);
        }

        var i;
        for (i = 0; i < vmpTag.length; i++) {
            if ('0123456'.indexOf(vmpTag[i]) >= 0) {
                var step = decryptFn(7 - i);
                if (typeof step === 'function') {
                    step(playerArg, addr, nal.byteLength, PAGE_HOST.length);
                }
            }
        }
        var finish = decryptFn(8);
        var decryptedLength = typeof finish === 'function'
            ? finish(playerArg, addr, nal.byteLength, PAGE_HOST.length)
            : 0;
        var out = Uint8Array.from(heap().subarray(addr, addr + decryptedLength));
        moduleInstance._jsfree(addr);
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

    function decryptPES(data, map, ts, stats) {
        var starts = findStartCodes(data);
        var n;
        for (n = 0; n < starts.length; n++) {
            var from = starts[n].nal;
            var to = n + 1 < starts.length ? starts[n + 1].nal - starts[n + 1].code : data.length;
            if (from >= to) continue;
            var decrypted;
            try {
                decrypted = decryptNAL(data.subarray(from, to));
            } catch (err) {
                throw err;
            }
            if (!decrypted) continue;
            stats.nals += 1;
            if (decrypted.length !== (to - from)) {
                stats.skipped += 1;
                continue;
            }
            var offset;
            for (offset = 0; offset < decrypted.length; offset++) {
                if (ts[map[from + offset]] !== decrypted[offset]) stats.changed += 1;
                ts[map[from + offset]] = decrypted[offset];
            }
        }
    }

    function isVideoPES(streamId) {
        return streamId >= 0xe0 && streamId <= 0xef;
    }

    function decryptTS(buffer, stats) {
        var ts = new Uint8Array(buffer);
        if (ts.length < 188 || ts[0] !== 0x47) {
            return ts;
        }
        var pes = [];
        var map = [];
        var activePid = -1;
        function flush() {
            if (!pes.length) return;
            decryptPES(Uint8Array.from(pes), map, ts, stats);
            pes = [];
            map = [];
            activePid = -1;
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
            if (payloadOff >= 188) continue;
            var cursor = packet + payloadOff;
            var end = packet + 188;
            if (start && end - cursor >= 9 && ts[cursor] === 0 && ts[cursor + 1] === 0 && ts[cursor + 2] === 1) {
                var streamId = ts[cursor + 3];
                if (!isVideoPES(streamId)) {
                    if (activePid === pid) flush();
                    continue;
                }
                flush();
                activePid = pid;
                cursor += 9 + ts[cursor + 8];
            } else if (pid !== activePid) {
                continue;
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
        shouldDecrypt = true;
        vmpTag = '';
        releasePlayerArg();
        initPlayer();
        sessionBegin = true;
    }

    function stopSession() {
        if (!sessionBegin) return;
        try { uninitPlayer(); } catch (err) {}
        sessionBegin = false;
        shouldDecrypt = true;
        vmpTag = '';
        releasePlayerArg();
    }

    window.__lwtvH5e = {
        isReady: function () { return ready && typeof CNTVModule === 'function'; },
        start: function () {
            window.__lwtvH5eConfigLoaded = false;
            startSession();
            return new Promise(function (resolve) {
                var n = 0;
                var timer = setInterval(function () {
                    n += 1;
                    if (window.__lwtvH5eConfigLoaded || n >= 40) {
                        clearInterval(timer);
                        resolve(window.__lwtvH5eConfigLoaded ? 'ok' : 'ok-timeout');
                    }
                }, 50);
            });
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
                var stats = { nals: 0, changed: 0, skipped: 0 };
                var out = decryptTS(buf, stats);
                return fetch('http://127.0.0.1:' + (window.__lwtvH5ePort || location.port) + '/outbox/' + id, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/octet-stream' },
                    body: out
                }).then(function (res) {
                    Date.now = originNow;
                    if (!res.ok) return 'put';
                    return 'ok nals=' + stats.nals + ' changed=' + stats.changed + ' skipped=' + stats.skipped + ' tag=' + vmpTag;
                });
            }).catch(function (err) {
                Date.now = originNow;
                try { stopSession(); startSession(); } catch (resetErr) {}
                return 'drop:' + String(err && err.message ? err.message : err);
            });
        }
    };

    waitForModule(function () {});
})();
