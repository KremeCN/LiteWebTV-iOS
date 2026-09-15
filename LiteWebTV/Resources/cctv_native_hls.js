(function () {
    'use strict';
    if (window !== window.top || window.__lwtvNativeHls) return;
    window.__lwtvNativeHls = true;

    var attached = false;
    var tries = 0;

    function post(msg) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                window.webkit.messageHandlers.bridge.postMessage({
                    type: 'console',
                    level: 'log',
                    data: '[CCTV] ' + msg
                });
            }
        } catch (e) { }
    }

    function hasMedia(video) {
        if (!video) return false;
        if (video.srcObject) return true;
        var attr = video.getAttribute('src') || '';
        if (attr.length > 8) return true;
        var current = video.currentSrc || '';
        if (current.length < 8) return false;
        try {
            var page = location.href.split('#')[0].split('?')[0];
            var cur = current.split('#')[0].split('?')[0];
            if (cur === page) return false;
        } catch (e) { }
        return true;
    }

    function httpsUrl(url) {
        if (location.protocol === 'https:' && url.indexOf('http://') === 0) {
            return 'https://' + url.slice(7);
        }
        return url;
    }

    function playerUrl() {
        try {
            var objs = window.livePlayerObjs;
            if (!objs) return '';
            var seen = [];
            if (objs.player && objs.player.video) seen.push(objs.player.video);
            for (var key in objs) {
                if (!Object.prototype.hasOwnProperty.call(objs, key)) continue;
                var item = objs[key];
                if (item && item.video) seen.push(item.video);
            }
            for (var i = 0; i < seen.length; i++) {
                var url = String(seen[i].url || seen[i].liveUrl || '');
                if (url.length > 8) return httpsUrl(url);
            }
        } catch (e) { }
        return '';
    }

    function targetVideo() {
        return document.querySelector('video[id^="h5player_"]') || document.querySelector('video');
    }

    function attach() {
        if (attached) return true;
        var url = playerUrl();
        var video = targetVideo();
        if (!url || !video) return false;
        if (hasMedia(video)) {
            attached = true;
            return true;
        }
        try {
            video.setAttribute('playsinline', '');
            video.setAttribute('webkit-playsinline', 'webkit-playsinline');
            video.src = url;
            if (typeof video.load === 'function') video.load();
            var playing = video.play();
            if (playing && typeof playing.catch === 'function') {
                playing.catch(function () { });
            }
            attached = true;
            post('native hls attached');
            return true;
        } catch (e) {
            post('native hls attach failed');
            return false;
        }
    }

    var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
    if (proto && !proto.__lwtvPlayWrapped) {
        var originalPlay = proto.play;
        proto.play = function () {
            if (hasMedia(this)) {
                return originalPlay.apply(this, arguments);
            }
            attach();
            if (hasMedia(this)) {
                return originalPlay.apply(this, arguments);
            }
            var self = this;
            return new Promise(function (resolve, reject) {
                var n = 0;
                var timer = setInterval(function () {
                    n += 1;
                    attach();
                    if (hasMedia(self)) {
                        clearInterval(timer);
                        var next = originalPlay.apply(self, arguments);
                        if (next && typeof next.then === 'function') next.then(resolve, reject);
                        else resolve();
                    } else if (n > 40) {
                        clearInterval(timer);
                        reject(new Error('no media src'));
                    }
                }, 50);
            });
        };
        proto.__lwtvPlayWrapped = true;
    }

    var poll = setInterval(function () {
        tries += 1;
        if (attach() || tries > 80) clearInterval(poll);
    }, 50);
})();
