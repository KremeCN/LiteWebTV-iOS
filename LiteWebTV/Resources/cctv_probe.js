(function () {
    'use strict';

    var documentID = String(Date.now()) + '-' + Math.random().toString(36).slice(2);
    var isMainFrame = window === window.top;
    var observer = null;
    var scanScheduled = false;
    var overlayPresent = null;
    var registered = false;

    function post(type, data) {
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

    function scanOverlay(force) {
        var body = (document.body && document.body.innerText) || '';
        var present = /本时段节目请使用电脑(?:端|客户端)|央视影音客户端观看/.test(body);
        if (!force && overlayPresent === present) return;
        overlayPresent = present;
        post('rightsOverlay', { present: present });
    }

    function scan(forceOverlay) {
        if (!registered) return;
        document.querySelectorAll('video').forEach(attachVideo);
        scanOverlay(!!forceOverlay);
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

    if (!isMainFrame) {
        registerDocument('subframe-initial');
    }
    setInterval(function () {
        if (registered) scanOverlay(false);
    }, 2000);
})();
