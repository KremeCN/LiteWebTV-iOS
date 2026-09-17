(function () {
    'use strict';

    var PAGE_HOST = 'https://tv.cctv.com';
    // NativeWasmTv / 官网直播播放器的 media tag，是 H5E 密钥状态的一部分。
    var MEDIA_TAG = 'h5player_player';
    var TAG_EXTEND = 2048;
    // jsdec 输出函数把分配块尾部当变换 scratch：合法 slice 需要接近 2 MiB。
    var NAL_MEMORY_EXTEND = 2 * 1024 * 1024;
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
        window.__lwtvH5eModule = instance;
        function markReady() {
            if (ready) return;
            ready = true;
            window.__lwtvH5eModule = moduleInstance;
            done(null);
        }
        if (moduleInstance && typeof moduleInstance.then === 'function') {
            moduleInstance.then(function (resolved) {
                if (resolved) {
                    moduleInstance = resolved;
                    window.__lwtvH5eModule = resolved;
                }
            });
        }
        function pollExports() {
            if (ready) return;
            var m = moduleInstance;
            // asm.aa 在 wasm 实例化后立刻就有，但 emscripten run() 还没跑完：
            // Fetch.staticInit 的 IndexedDB 打开是异步的，dbInstance 未定时
            // InitPlayer 会直接走错误分支、连 env.q 都不调（last=boot/pending=0 的根因）。
            // 必须等 calledRun（onRuntimeInitialized 之后）再开始会话。
            if (m && m.calledRun === true && m.asm && typeof m.asm.aa === 'function') {
                markReady();
                return;
            }
            setTimeout(pollExports, 50);
        }
        pollExports();
    }

    function heap() {
        return moduleInstance.HEAPU8 || moduleInstance.HEAP8;
    }

    function allocTag(tag) {
        var memory = moduleInstance._jsmalloc(tag.length + TAG_EXTEND);
        heap().fill(0, memory, memory + tag.length + TAG_EXTEND);
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

    // wasm 里 InitPlayer 触发的 H5player.json fetch 被 hook 挂起到这里。
    // 官方语义是异步回调：必须等 InitPlayer 返回后再写响应并触发回调。
    function completePendingFetch() {
        var ptr = window.__lwtvH5ePendingFetch;
        if (!ptr) return false;
        window.__lwtvH5ePendingFetch = 0;
        var H5PLAYER_JSON = '{"h5player":{"ver":20190904,"md5":"c7ed5a71dbe4dee1a2ba171f660ee98d","BTime":"2019-09-04-20:25:10"}}';
        try {
            var payload = new TextEncoder().encode(H5PLAYER_JSON);
            var dataPtr = moduleInstance._malloc(payload.length);
            moduleInstance.HEAPU8.set(payload, dataPtr);
            var heap32 = moduleInstance.HEAPU32;
            var heap16 = moduleInstance.HEAPU16;
            heap32[(ptr + 12) >> 2] = dataPtr;
            heap32[(ptr + 16) >> 2] = payload.length;
            heap32[(ptr + 20) >> 2] = 0;
            heap32[(ptr + 24) >> 2] = 0;
            heap32[(ptr + 28) >> 2] = 0;
            heap32[(ptr + 32) >> 2] = payload.length;
            heap32[(ptr + 36) >> 2] = 0;
            heap16[(ptr + 40) >> 1] = 4;
            heap16[(ptr + 42) >> 1] = 200;
            var i;
            var status = 'OK';
            for (i = 0; i < status.length; i++) {
                moduleInstance.HEAPU8[ptr + 44 + i] = status.charCodeAt(i);
            }
            moduleInstance.HEAPU8[ptr + 44 + status.length] = 0;
            var onsuccess = heap32[(ptr + 148) >> 2];
            var onready = heap32[(ptr + 160) >> 2];
            if (onsuccess && typeof moduleInstance.dynCall_vi === 'function') {
                moduleInstance.dynCall_vi(onsuccess, ptr);
            }
            if (onready && typeof moduleInstance.dynCall_vi === 'function') {
                moduleInstance.dynCall_vi(onready, ptr);
            }
            window.__lwtvH5eConfigLoaded = true;
            return true;
        } catch (err) {
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + '|complete-err:' + err;
            return false;
        }
    }

    function updatePlayer() {
        var raw = moduleInstance._CNTV_UpdatePlayer(playerArg);
        vmpTag = (raw >>> 0).toString(16).padStart(8, '0');
    }

    function decryptNAL(nal) {
        if (!nal || !nal.length) return null;
        var type = nal[0] & 0x1f;
        if (type === 25) {
            shouldDecrypt = nal.length > 1 && nal[1] === 1;
            return Uint8Array.from(nal);
        }

        updatePlayer();
        var addr = moduleInstance._jsmalloc(nal.byteLength + PAGE_HOST.length + NAL_MEMORY_EXTEND);
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
        if (!decryptedLength || decryptedLength > nal.byteLength + PAGE_HOST.length + NAL_MEMORY_EXTEND) {
            moduleInstance._jsfree(addr);
            return null;
        }
        var out = Uint8Array.from(heap().subarray(addr, addr + decryptedLength));
        moduleInstance._jsfree(addr);
        if (type === 7 && out.length >= 3) {
            out[2] = out[2] & 0xfc;
        }
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

    function writePES(ts, slots, headerPacket, headerOff, headerLen, packetLen, bytes, stats) {
        var consumed = 0;
        var total = 0;
        var s;
        for (s = 0; s < slots.length; s++) total += slots[s].len;
        if (bytes.length > total) {
            stats.skipped += 1;
            return false;
        }
        for (s = 0; s < slots.length; s++) {
            var slot = slots[s];
            var packet = slot.packet;
            var available = bytes.length - consumed;
            if (available >= slot.len) {
                ts.set(bytes.subarray(consumed, consumed + slot.len), packet + slot.off);
                consumed += slot.len;
                continue;
            }
            if (available > 0) {
                var adaptationLength = 183 - available;
                ts[packet + 3] = (ts[packet + 3] & 0xcf) | 0x30;
                ts[packet + 4] = adaptationLength;
                if (adaptationLength > 0) {
                    ts[packet + 5] = 0;
                    if (adaptationLength > 1) {
                        ts.fill(0xff, packet + 6, packet + 6 + adaptationLength - 1);
                    }
                }
                ts.set(bytes.subarray(consumed, consumed + available), packet + 188 - available);
                consumed += available;
            } else {
                ts[packet + 3] = (ts[packet + 3] & 0xcf) | 0x30;
                ts[packet + 4] = 183;
                ts[packet + 5] = 0;
                ts.fill(0xff, packet + 6, packet + 188);
            }
        }
        if (consumed !== bytes.length) {
            stats.skipped += 1;
            return false;
        }
        if (packetLen > 0 && headerLen >= 6 && packetLen >= headerLen - 6) {
            var updated = bytes.length + headerLen - 6;
            if (updated <= 0xffff) {
                ts[headerPacket + headerOff + 4] = (updated >> 8) & 0xff;
                ts[headerPacket + headerOff + 5] = updated & 0xff;
            }
        }
        stats.changed += bytes.length;
        return true;
    }

    function decryptPES(data, slots, ts, headerPacket, headerOff, headerLen, packetLen, stats) {
        var starts = findStartCodes(data);
        if (!starts.length) return;
        var pieces = [];
        var total = 0;
        var n;
        var lead = starts[0].nal - starts[0].code;
        if (lead > 0) {
            pieces.push(data.subarray(0, lead));
            total += lead;
        }
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
            // 解失败就整段 PES 原样留下，避免明文和密文拼在一起变成绿点花屏。
            if (!decrypted) {
                stats.skipped += 1;
                return;
            }
            stats.nals += 1;
            var prefix = starts[n].code === 4
                ? new Uint8Array([0, 0, 0, 1])
                : new Uint8Array([0, 0, 1]);
            pieces.push(prefix, decrypted);
            total += prefix.length + decrypted.length;
        }
        if (!pieces.length) return;
        var rebuilt = new Uint8Array(total);
        var off = 0;
        for (n = 0; n < pieces.length; n++) {
            rebuilt.set(pieces[n], off);
            off += pieces[n].length;
        }
        writePES(ts, slots, headerPacket, headerOff, headerLen, packetLen, rebuilt, stats);
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
        var slots = [];
        var activePid = -1;
        var pesHeaderLen = 0;
        var pesPacketLen = 0;
        var headerPacket = 0;
        var headerOff = 0;
        function flush() {
            if (!pes.length) {
                activePid = -1;
                pesHeaderLen = 0;
                pesPacketLen = 0;
                slots = [];
                return;
            }
            if (pesPacketLen > 0 && pesHeaderLen >= 6 && pesPacketLen >= pesHeaderLen - 6) {
                var expected = pesPacketLen - (pesHeaderLen - 6);
                if (pes.length < expected) {
                    pes = [];
                    slots = [];
                    activePid = -1;
                    pesHeaderLen = 0;
                    pesPacketLen = 0;
                    return;
                }
                if (pes.length > expected) {
                    var remain = expected;
                    var trimmed = [];
                    var s;
                    for (s = 0; s < slots.length && remain > 0; s++) {
                        var take = Math.min(slots[s].len, remain);
                        trimmed.push({ packet: slots[s].packet, off: slots[s].off, len: take });
                        remain -= take;
                    }
                    slots = trimmed;
                    pes = pes.slice(0, expected);
                }
            }
            decryptPES(Uint8Array.from(pes), slots, ts, headerPacket, headerOff, pesHeaderLen, pesPacketLen, stats);
            pes = [];
            slots = [];
            activePid = -1;
            pesHeaderLen = 0;
            pesPacketLen = 0;
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
                headerPacket = packet;
                headerOff = cursor - packet;
                pesPacketLen = (ts[cursor + 4] << 8) | ts[cursor + 5];
                pesHeaderLen = 9 + ts[cursor + 8];
                cursor += pesHeaderLen;
            } else if (pid !== activePid) {
                continue;
            }
            if (cursor < end) {
                slots.push({ packet: packet, off: cursor - packet, len: end - cursor });
                for (; cursor < end; cursor++) {
                    pes.push(ts[cursor]);
                }
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
        try {
            initPlayer();
            completePendingFetch();
            sessionBegin = true;
        } catch (err) {
            window.__lwtvH5eLastFetch = (window.__lwtvH5eLastFetch || '') + '|init-err:' + err;
            throw err;
        }
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
            try {
                startSession();
            } catch (err) {
                return Promise.resolve('start-err ' + String(err) + ' last=' + (window.__lwtvH5eLastFetch || ''));
            }
            return new Promise(function (resolve) {
                var n = 0;
                var timer = setInterval(function () {
                    n += 1;
                    if (window.__lwtvH5eConfigLoaded || n >= 80) {
                        clearInterval(timer);
                        var diag = ' last=' + (window.__lwtvH5eLastFetch || '') +
                            ' boot=' + (window.__lwtvH5eBoot ? '1' : '0') +
                            ' wrap=' + (window.__lwtvH5eWrap ? '1' : '0') +
                            ' patched=' + (window.__lwtvH5eWorkerPatched ? '1' : '0') +
                            (window.__lwtvH5eWorkerPatchErr ? ' patcherr=' + window.__lwtvH5eWorkerPatchErr : '') +
                            ' pending=' + (window.__lwtvH5ePendingFetch || 0);
                        resolve((window.__lwtvH5eConfigLoaded ? 'ok' : 'ok-timeout') + diag);
                    }
                }, 50);
            });
        },
        stop: function () {
            stopSession();
            return 'ok';
        },
        decryptInbox: function (id) {
            if (!ready) return Promise.resolve('not-ready');
            var frozen = originNow();
            Date.now = function () { return frozen; };
            try {
                // UpdatePlayer 连续跑几个分片后 VMP 会错；NativeWasmTv 每个 TS 都 Uninit+Init。
                startSession();
            } catch (err) {
                Date.now = originNow;
                return Promise.resolve('drop:reset ' + String(err) + ' last=' + (window.__lwtvH5eLastFetch || ''));
            }
            if (!window.__lwtvH5eConfigLoaded) {
                Date.now = originNow;
                return Promise.resolve('drop:noconfig last=' + (window.__lwtvH5eLastFetch || '') +
                    ' pending=' + (window.__lwtvH5ePendingFetch || 0));
            }
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
