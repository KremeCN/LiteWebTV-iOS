(function () {
    'use strict';
    if (window !== window.top || window.__lwtvNativeHls) return;
    window.__lwtvNativeHls = true;

    var attached = false;
    var originalPlay = null;
    var originalPause = null;
    var recovering = false;

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
        var videos = document.querySelectorAll('video');
        var best = null;
        for (var i = 0; i < videos.length; i++) {
            if (!hasMedia(videos[i])) continue;
            if (!best || videos[i].videoWidth > best.videoWidth) best = videos[i];
        }
        return best || document.querySelector('video[id^="h5player_"]') || videos[0] || null;
    }

    function hasDecodedFrame(video) {
        return !!(video && video.videoWidth > 1 && video.readyState >= 2);
    }

    function quietAutoplay(video) {
        if (!video) return;
        try {
            video.autoplay = false;
            video.removeAttribute('autoplay');
            video.setAttribute('playsinline', '');
            video.setAttribute('webkit-playsinline', '');
            video.setAttribute('x5-playsinline', 'true');
        } catch (e) { }
    }

    function hideFalseOverlay() {
        document.querySelectorAll('[id^="error_msg_"]').forEach(function (el) {
            el.style.setProperty('display', 'none', 'important');
            el.style.setProperty('visibility', 'hidden', 'important');
            el.style.setProperty('opacity', '0', 'important');
            el.style.setProperty('pointer-events', 'none', 'important');
        });
    }

    function revealIfDecoded() {
        var video = targetVideo();
        if (!hasDecodedFrame(video)) return false;
        recovering = true;
        hideFalseOverlay();
        try {
            video.style.setProperty('display', 'block', 'important');
            video.style.setProperty('visibility', 'visible', 'important');
            video.style.setProperty('opacity', '1', 'important');
            video.style.setProperty('width', '100%', 'important');
            video.style.setProperty('height', '100%', 'important');
        } catch (e) { }
        if (video.paused && originalPlay) {
            try {
                var playing = originalPlay.call(video);
                if (playing && typeof playing.catch === 'function') playing.catch(function () { });
            } catch (e) { }
        }
        if (!video.__lwtvRevealed) {
            video.__lwtvRevealed = true;
            post('native hls revealed ' + video.videoWidth + 'x' + video.videoHeight + ' paused=' + video.paused);
        }
        if (window.Android && window.Android.dismissSplash) {
            window.Android.dismissSplash();
        }
        return true;
    }

    function bindReveal(video) {
        if (!video || video.__lwtvRevealBound) return;
        video.__lwtvRevealBound = true;
        ['loadedmetadata', 'loadeddata', 'canplay', 'playing', 'resize', 'timeupdate'].forEach(function (name) {
            video.addEventListener(name, function () {
                try { revealIfDecoded(); } catch (e) { }
            });
        });
    }

    function attachSrc() {
        var url = playerUrl();
        var video = targetVideo();
        if (!video) {
            video = document.querySelector('video');
        }
        if (!video) return false;
        quietAutoplay(video);
        bindReveal(video);
        if (hasMedia(video)) {
            attached = true;
            return true;
        }
        if (!url) return false;
        try {
            quietAutoplay(video);
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
        originalPause = proto.pause;
        proto.play = function () {
            var self = this;
            var args = arguments;
            quietAutoplay(self);
            attachSrc();
            if (canStart(self) || hasDecodedFrame(self)) {
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
                    if (!(canStart(self) || hasDecodedFrame(self))) return false;
                    try {
                        finishOk(originalPlay.apply(self, args));
                    } catch (e) {
                        return false;
                    }
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
        proto.pause = function () {
            if (recovering && hasDecodedFrame(this)) return;
            return originalPause.apply(this, arguments);
        };
        proto.__lwtvPlayWrapped = true;
    }

    function tick() {
        try {
            document.querySelectorAll('video').forEach(quietAutoplay);
            attachSrc();
            revealIfDecoded();
        } catch (e) { }
        var decoded = hasDecodedFrame(targetVideo());
        setTimeout(tick, decoded ? 400 : 50);
    }
    tick();

    try {
        var scheduled = false;
        function schedule() {
            if (scheduled) return;
            scheduled = true;
            setTimeout(function () {
                scheduled = false;
                try {
                    document.querySelectorAll('video').forEach(quietAutoplay);
                    attachSrc();
                    revealIfDecoded();
                } catch (e) { }
            }, 0);
        }
        var observer = new MutationObserver(schedule);
        observer.observe(document.documentElement, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ['style', 'class', 'autoplay', 'src']
        });
    } catch (e) { }
})();
