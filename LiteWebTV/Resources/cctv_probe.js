(function () {
    'use strict';

    var documentID = String(Date.now()) + '-' + Math.random().toString(36).slice(2);
    var isMainFrame = window === window.top;
    var observer = null;
    var scanScheduled = false;
    var overlayPresent = null;
    var overlayKind = '';
    var registered = false;
    var pendingPosts = [];
    var lastBranchKey = '';
    var MAX_PENDING = 30;

    function emit(type, data) {
        try {
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.diag) {
                return;
            }
            window.webkit.messageHandlers.diag.postMessage({
                type: type,
                data: data || {},
                href: String(location.origin + location.pathname),
                ua: String(navigator.userAgent || ''),
                appVersion: String(navigator.appVersion || ''),
                session: Number(window.__lwtvProbeSession || 0),
                documentID: documentID,
                mainFrame: isMainFrame,
                navigationID: String(window.__lwtvNativeNavigationID || '')
            });
        } catch (e) { }
    }

    function post(type, data) {
        if (!registered && type !== 'probeReady') {
            if (pendingPosts.length < MAX_PENDING) {
                pendingPosts.push({ type: type, data: data || {} });
            }
            return;
        }
        emit(type, data);
    }

    function flushPending() {
        var queued = pendingPosts.splice(0, pendingPosts.length);
        queued.forEach(function (item) {
            emit(item.type, item.data);
        });
    }

    function safeSrc(video) {
        try {
            var raw = video.currentSrc || video.src || '';
            if (!raw) return '';
            var url = new URL(raw, location.href);
            return url.origin + url.pathname;
        } catch (e) {
            return '';
        }
    }

    function describeVideo(video) {
        var err = video.error;
        return {
            src: safeSrc(video),
            ready: video.readyState,
            network: video.networkState,
            paused: video.paused,
            muted: video.muted,
            w: video.videoWidth || 0,
            h: video.videoHeight || 0,
            t: Math.round(Number(video.currentTime || 0)),
            playsinline: video.hasAttribute('playsinline'),
            error: err ? { code: err.code } : null
        };
    }

    function attachVideo(video) {
        if (!video || video.getAttribute('data-lwtv-diag') === '1') return;
        video.setAttribute('data-lwtv-diag', '1');
        post('video', { event: 'found', video: describeVideo(video) });
        ['loadedmetadata', 'playing', 'waiting', 'stalled', 'error', 'pause', 'emptied'].forEach(function (name) {
            video.addEventListener(name, function () {
                post('video', { event: name, video: describeVideo(video) });
            });
        });
        var lastBucket = -1;
        video.addEventListener('timeupdate', function () {
            var bucket = Math.floor((video.currentTime || 0) / 30);
            if (bucket === lastBucket) return;
            lastBucket = bucket;
            post('video', { event: 'progress', video: describeVideo(video) });
        });
    }

    function overlayText() {
        var chunks = [];
        if (document.body && document.body.innerText) {
            chunks.push(document.body.innerText);
        }
        document.querySelectorAll('[id^="error_msg_"]').forEach(function (el) {
            chunks.push(el.innerText || el.textContent || '');
        });
        return chunks.join('\n');
    }

    function classifyTip(text) {
        if (/电脑端或央视影音/.test(text)) return 'use-pc-or-cbox';
        if (/本时段节目请使用电脑端观看/.test(text)) return 'use-pc';
        if (/版权/.test(text)) return 'copyright';
        if (text && /无法播放|不支持播放/.test(text)) return 'cannot-play';
        return text ? 'other' : 'none';
    }

    function scanOverlay(force) {
        var text = overlayText();
        var jump = !!document.querySelector('[id^="jump_to_app_"]');
        var present = /本时段节目请使用电脑(?:端|客户端)|央视影音客户端观看/.test(text) || jump;
        var kind = jump ? 'jump-to-app' : classifyTip(text);
        var snippet = '';
        var errorNode = document.querySelector('[id^="error_msg_"]');
        if (errorNode) {
            snippet = String(errorNode.innerText || errorNode.textContent || '').replace(/\s+/g, ' ').slice(0, 80);
        }
        if (!force && overlayPresent === present && overlayKind === kind) return;
        overlayPresent = present;
        overlayKind = kind;
        post('rightsOverlay', { present: present, kind: kind, snippet: snippet });
    }

    function classifyMediaUrl(url) {
        if (!url) return 'empty';
        var value = String(url);
        if (/cdrm|drm/i.test(value)) return 'drm-like';
        if (/\.m3u8/i.test(value)) return 'm3u8';
        return 'other';
    }

    function playerBranchSnapshot() {
        var ua = navigator.userAgent || '';
        var appVersion = navigator.appVersion || '';
        var matched = appVersion.match(/OS (\d+)_(\d+)/);
        var safari = /safari/i.test(ua) && !/chrome/i.test(ua) && !/qqbrowser/i.test(ua);
        var iosHttps = /(iphone|ipad)/i.test(ua) && /https:\/\//i.test(location.href || '');
        var objs = window.livePlayerObjs || {};
        var player = objs.player || {};
        var video = player.video || {};
        var drmFn = '';
        try {
            if (typeof isIosDrmPlayer === 'function' && window.playerParas) {
                drmFn = isIosDrmPlayer(window.playerParas) ? 'true' : 'false';
            }
        } catch (e) {
            drmFn = 'threw';
        }
        return {
            safari: safari,
            iosHttps: iosHttps,
            iosVer: matched ? (matched[1] + '.' + matched[2]) : '',
            wasm: typeof WebAssembly !== 'undefined',
            mse: !!(window.MediaSource || window.WebKitMediaSource || window.ManagedMediaSource),
            eme: typeof navigator.requestMediaKeySystemAccess === 'function',
            jumpToApp: String((player.jumpToApp || (window.playerParas && window.playerParas.jumpToApp) || '')),
            isDrm: !!player.isDrm,
            isIosDrmFlag: !!objs.isIosDrm,
            isIosDrmFn: drmFn,
            videoUrlKind: classifyMediaUrl(video.url || video.liveUrl || '')
        };
    }

    function maybePostBranch(force) {
        var snapshot = playerBranchSnapshot();
        var key = JSON.stringify(snapshot);
        if (!force && key === lastBranchKey) return;
        lastBranchKey = key;
        post('playerBranch', snapshot);
    }

    function isVdnUrl(url) {
        return /vdn.*\.cntv\.cn|liveHtml5\.do|\/api\/v3\/vdn\//i.test(String(url || ''));
    }

    function describeVdnRequest(rawUrl) {
        try {
            var parsed = new URL(rawUrl, location.href);
            var params = {};
            ['pdrm', 'channel', 'tai', 'client', 'vn'].forEach(function (key) {
                if (parsed.searchParams.has(key)) {
                    params[key] = String(parsed.searchParams.get(key) || '');
                }
            });
            return { host: parsed.host, path: parsed.pathname, params: params };
        } catch (e) {
            return { host: '', path: '', params: {} };
        }
    }

    function describeVdnBody(text) {
        var info = {
            parse: 'empty',
            ack: '',
            play: '',
            pub: '',
            hasHlsNd: false,
            hasHlsCdrm: false,
            hasBackupNd: false,
            hasBackupCdrm: false,
            manifestKeys: '',
            backupKeys: '',
            tipKind: 'none'
        };
        if (!text) return info;
        var start = text.indexOf('{');
        var end = text.lastIndexOf('}');
        if (start < 0 || end <= start) {
            info.parse = 'nonjson';
            return info;
        }
        var json;
        try {
            json = JSON.parse(text.slice(start, end + 1));
        } catch (e) {
            info.parse = 'invalid';
            return info;
        }
        info.parse = 'ok';
        info.ack = String(json.ack || '');
        info.play = json.play === undefined ? 'missing' : String(json.play);
        info.pub = json.public === undefined ? '' : String(json.public);
        var manifest = json.manifest || {};
        var backup = json.backup || {};
        info.manifestKeys = Object.keys(manifest).sort().join(',');
        info.backupKeys = Object.keys(backup).sort().join(',');
        info.hasHlsNd = !!(manifest.hls_nd && String(manifest.hls_nd).length >= 4);
        info.hasHlsCdrm = !!(manifest.hls_cdrm && String(manifest.hls_cdrm).length >= 4);
        info.hasBackupNd = !!(backup.hls_nd && String(backup.hls_nd).length >= 4);
        info.hasBackupCdrm = !!(backup.hls_cdrm && String(backup.hls_cdrm).length >= 4);
        info.tipKind = classifyTip(String(json.tip_msg || ''));
        return info;
    }

    function reportVdn(rawUrl, bodyText, status) {
        var request = describeVdnRequest(rawUrl);
        var response = describeVdnBody(bodyText);
        post('vdn', {
            host: request.host,
            path: request.path,
            pdrm: request.params.pdrm || '',
            channel: request.params.channel || '',
            tai: request.params.tai || '',
            client: request.params.client || '',
            vn: request.params.vn || '',
            status: Number(status || 0),
            parse: response.parse,
            ack: response.ack,
            play: response.play,
            pub: response.pub,
            hasHlsNd: response.hasHlsNd,
            hasHlsCdrm: response.hasHlsCdrm,
            hasBackupNd: response.hasBackupNd,
            hasBackupCdrm: response.hasBackupCdrm,
            manifestKeys: response.manifestKeys,
            backupKeys: response.backupKeys,
            tipKind: response.tipKind
        });
        maybePostBranch(true);
        scanOverlay(true);
    }

    function installNetworkHooks() {
        if (!isMainFrame || window.__lwtvVdnHooked) return;
        window.__lwtvVdnHooked = true;
        try {
            var proto = XMLHttpRequest.prototype;
            var originalOpen = proto.open;
            var originalSend = proto.send;
            proto.open = function (method, url) {
                try { this.__lwtvUrl = String(url || ''); } catch (e) { }
                return originalOpen.apply(this, arguments);
            };
            proto.send = function () {
                try {
                    this.addEventListener('loadend', function () {
                        try {
                            if (!isVdnUrl(this.__lwtvUrl)) return;
                            reportVdn(this.__lwtvUrl, this.responseText, this.status);
                        } catch (e) { }
                    });
                } catch (e) { }
                return originalSend.apply(this, arguments);
            };
        } catch (e) { }
        try {
            if (typeof window.fetch === 'function') {
                var originalFetch = window.fetch;
                window.fetch = function (input) {
                    var url = '';
                    try {
                        url = typeof input === 'string' ? input : String((input && input.url) || '');
                    } catch (e) { }
                    return originalFetch.apply(this, arguments).then(function (response) {
                        try {
                            if (!isVdnUrl(url || response.url)) return response;
                            response.clone().text().then(function (text) {
                                reportVdn(url || response.url, text, response.status);
                            });
                        } catch (e) { }
                        return response;
                    });
                };
            }
        } catch (e) { }
    }

    function scan(forceOverlay) {
        if (!registered) return;
        document.querySelectorAll('video').forEach(attachVideo);
        scanOverlay(!!forceOverlay);
        maybePostBranch(!!forceOverlay);
    }

    function scheduleScan() {
        if (scanScheduled) return;
        scanScheduled = true;
        setTimeout(function () {
            scanScheduled = false;
            scan(false);
        }, 0);
    }

    function installObserver() {
        if (observer || !document.documentElement) return false;
        observer = new MutationObserver(scheduleScan);
        observer.observe(document.documentElement, { childList: true, subtree: true });
        return true;
    }

    function ensureObserver() {
        if (installObserver()) {
            scan(true);
            return;
        }
        if (!document.documentElement) {
            document.addEventListener('DOMContentLoaded', function () {
                installObserver();
                scan(true);
            }, { once: true });
        } else {
            scan(true);
        }
    }

    function registerDocument(reason) {
        if (isMainFrame && !window.__lwtvNativeNavigationID) return;
        registered = true;
        post('probeReady', { readyState: document.readyState, reason: reason || 'initial' });
        flushPending();
        ensureObserver();
    }

    window.__lwtvRegisterNativeDocument = function (navigationID) {
        window.__lwtvNativeNavigationID = String(navigationID || '');
        registerDocument('native-commit');
    };

    window.addEventListener('error', function (event) {
        var filePath = '';
        try {
            filePath = event.filename ? new URL(event.filename, location.href).pathname : '';
        } catch (e) { }
        post('pageError', {
            name: event.error && event.error.name ? String(event.error.name) : 'Error',
            filePath: filePath,
            line: event.lineno || 0,
            column: event.colno || 0
        });
    });
    window.addEventListener('unhandledrejection', function (event) {
        post('unhandledRejection', { name: event.reason && event.reason.name ? String(event.reason.name) : '' });
    });
    window.addEventListener('pagehide', function (event) {
        post('documentClosed', { persisted: !!event.persisted });
        registered = false;
    });
    window.addEventListener('pageshow', function (event) {
        if (event.persisted || !registered) {
            registerDocument(event.persisted ? 'bfcache-restore' : 'pageshow');
        }
    });

    installNetworkHooks();
    if (!isMainFrame) {
        registerDocument('subframe-initial');
    }
    setInterval(function () {
        if (registered) {
            scanOverlay(false);
            maybePostBranch(false);
        }
    }, 2000);
})();
