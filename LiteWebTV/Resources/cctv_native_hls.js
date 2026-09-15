(function () {
    'use strict';
    if (window !== window.top || window.__lwtvNativeHls) return;
    window.__lwtvNativeHls = true;

    var attached = false;
    var originalPlay = null;

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

    function bindReveal(video) {
        if (!video || video.__lwtvRevealBound) return;
        video.__lwtvRevealBound = true;
        video.addEventListener('loadedmetadata', revealIfDecoded);
        video.addEventListener('canplay', revealIfDecoded);
        video.addEventListener('playing', revealIfDecoded);
        video.addEventListener('resize', revealIfDecoded);
    }

    function revealIfDecoded() {
        var video = targetVideo();
        if (!video || video.videoWidth < 2) return;
        video.style.setProperty('display', 'block', 'important');
        document.querySelectorAll('[id^="error_msg_"]').forEach(function (el) {
            el.style.setProperty('display', 'none', 'important');
        });
        if (video.paused && originalPlay) {
            var playing = originalPlay.call(video);
            if (playing && typeof playing.catch === 'function') playing.catch(function () { });
        }
        if (!video.__lwtvRevealed) {
            video.__lwtvRevealed = true;
            post('native hls revealed ' + video.videoWidth + 'x' + video.videoHeight);
        }
        if (window.Android && window.Android.dismissSplash) {
            window.Android.dismissSplash();
        }
    }

    function attachSrc() {
        var url = playerUrl();
        var video = targetVideo();
        if (!video) return false;
        if (hasMedia(video)) {
            attached = true;
            bindReveal(video);
            return true;
        }
        if (!url) return false;
        try {
            video.setAttribute('playsinline', '');
            video.setAttribute('webkit-playsinline', '');
            video.src = url;
            if (typeof video.load === 'function') video.load();
            attached = true;
            bindReveal(video);
            post('native hls src assigned');
            return true;
        } catch (e) {
            post('native hls attach failed');
            return false;
        }
    }

    function canStart(media) {
        return hasMedia(media) && media.readyState >= 3;
    }

    var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
    if (proto && !proto.__lwtvPlayWrapped) {
        originalPlay = proto.play;
        proto.play = function () {
            var self = this;
            var args = arguments;
            attachSrc();
            if (canStart(self)) {
                return originalPlay.apply(self, args);
            }
            if (self.__lwtvPlayWait) return self.__lwtvPlayWait;
            self.__lwtvPlayWait = new Promise(function (resolve, reject) {
                var settled = false;
                function finishOk(next) {
                    if (settled) return;
                    settled = true;
                    self.__lwtvPlayWait = null;
                    if (next && typeof next.then === 'function') next.then(resolve, reject);
                    else resolve();
                }
                function tryStart() {
                    attachSrc();
                    if (!canStart(self)) return false;
                    finishOk(originalPlay.apply(self, args));
                    return true;
                }
                function onReady() {
                    if (tryStart()) {
                        self.removeEventListener('canplay', onReady);
                        self.removeEventListener('loadeddata', onReady);
                    }
                }
                self.addEventListener('canplay', onReady);
                self.addEventListener('loadeddata', onReady);
                var timer = setInterval(function () {
                    if (tryStart() || settled) {
                        clearInterval(timer);
                        self.removeEventListener('canplay', onReady);
                        self.removeEventListener('loadeddata', onReady);
                    }
                }, 50);
            });
            return self.__lwtvPlayWait;
        };
        proto.__lwtvPlayWrapped = true;
    }

    function tick() {
        attachSrc();
        revealIfDecoded();
        var decoded = targetVideo() && targetVideo().videoWidth > 1;
        setTimeout(tick, decoded ? 1000 : 50);
    }
    tick();
})();
