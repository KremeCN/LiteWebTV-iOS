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

    function allVideos() {
        return Array.prototype.slice.call(document.querySelectorAll('video'));
    }

    function isActiveStream(video) {
        if (!video || !hasMedia(video)) return false;
        if (video.readyState >= 2 && (video.videoWidth > 1 || !video.paused)) return true;
        if (!video.paused && video.readyState >= 1) return true;
        return false;
    }

    function targetVideo(preferred) {
        if (preferred && isActiveStream(preferred)) return preferred;
        var videos = allVideos();
        var best = null;
        var bestScore = -1;
        for (var i = 0; i < videos.length; i++) {
            var video = videos[i];
            if (!hasMedia(video)) continue;
            var score = (video.videoWidth || 0) + (video.paused ? 0 : 10000) + (video.readyState * 10);
            if (score > bestScore) {
                best = video;
                bestScore = score;
            }
        }
        if (best) return best;
        if (preferred) return preferred;
        return document.querySelector('video[id^="h5player_"]') || videos[0] || null;
    }

    function quietAutoplay(video) {
        if (!video) return;
        try {
            video.autoplay = false;
            video.removeAttribute('autoplay');
            video.setAttribute('playsinline', 'true');
            video.setAttribute('webkit-playsinline', 'true');
            video.playsInline = true;
        } catch (e) { }
    }

    function ensureStyle() {
        if (document.getElementById('lwtv-cctv-surface')) return;
        var style = document.createElement('style');
        style.id = 'lwtv-cctv-surface';
        style.textContent = [
            'html.lwtv-cctv-playing [id^="error_msg_"],',
            'html.lwtv-cctv-playing [id^="h5canvas_"],',
            'html.lwtv-cctv-playing [id^="jump_to_app_"],',
            'html.lwtv-cctv-playing [id^="logo_"],',
            'html.lwtv-cctv-playing [id^="loading_"] {',
            '  display: none !important;',
            '  visibility: hidden !important;',
            '  pointer-events: none !important;',
            '}',
            'html.lwtv-cctv-playing video[id^="h5player_"] {',
            '  display: block !important;',
            '  width: 100% !important;',
            '  height: 100% !important;',
            '  object-fit: contain !important;',
            '  background: transparent !important;',
            '}'
        ].join('\n');
        (document.head || document.documentElement).appendChild(style);
    }

    function playerHost(video) {
        var id = video && video.id ? String(video.id) : '';
        if (id.indexOf('h5player_') === 0) {
            var host = document.getElementById(id.slice(9));
            if (host) return host;
        }
        return video && video.parentElement;
    }

    function surfaceVideo(video) {
        ensureStyle();
        document.documentElement.classList.add('lwtv-cctv-playing');
        var host = playerHost(video);
        if (host && !host.__lwtvHosted) {
            host.__lwtvHosted = true;
            try {
                host.style.setProperty('position', 'fixed', 'important');
                host.style.setProperty('left', '0', 'important');
                host.style.setProperty('top', '0', 'important');
                host.style.setProperty('width', '100%', 'important');
                host.style.setProperty('height', '100%', 'important');
                host.style.setProperty('z-index', '9999', 'important');
                host.style.setProperty('background', '#000', 'important');
                host.style.setProperty('overflow', 'hidden', 'important');
            } catch (e) { }
        }
        if (video.__lwtvSurfaced) return;
        video.__lwtvSurfaced = true;
        try {
            video.style.removeProperty('background');
            video.style.removeProperty('position');
            video.style.removeProperty('z-index');
            video.style.removeProperty('opacity');
            video.style.setProperty('display', 'block', 'important');
            video.style.setProperty('width', '100%', 'important');
            video.style.setProperty('height', '100%', 'important');
            video.style.setProperty('object-fit', 'contain', 'important');
            video.style.setProperty('background', 'transparent', 'important');
        } catch (e) { }
    }

    function revealIfDecoded(preferred) {
        var video = targetVideo(preferred);
        if (!isActiveStream(video)) return false;
        recovering = true;
        surfaceVideo(video);
        if (video.paused && originalPlay) {
            try {
                var playing = originalPlay.call(video);
                if (playing && typeof playing.catch === 'function') playing.catch(function () { });
            } catch (e) { }
        }
        if (!video.__lwtvRevealed) {
            video.__lwtvRevealed = true;
            post('native hls revealed ' + video.videoWidth + 'x' + video.videoHeight + ' paused=' + video.paused + ' ready=' + video.readyState);
        }
        if (window.Android && window.Android.dismissSplash) {
            window.Android.dismissSplash();
        }
        return true;
    }

    function bindReveal(video) {
        if (!video || video.__lwtvRevealBound) return;
        video.__lwtvRevealBound = true;
        ['loadedmetadata', 'loadeddata', 'canplay', 'playing', 'resize', 'timeupdate', 'stalled'].forEach(function (name) {
            video.addEventListener(name, function () {
                try { revealIfDecoded(video); } catch (e) { }
            });
        });
    }

    function attachSrc() {
        allVideos().forEach(function (video) {
            quietAutoplay(video);
            bindReveal(video);
        });
        var url = playerUrl();
        var video = targetVideo();
        if (!video) video = document.querySelector('video');
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
            if (canStart(self) || isActiveStream(self)) {
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
                    if (!(canStart(self) || isActiveStream(self))) return false;
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
            return originalPause.apply(this, arguments);
        };
        proto.__lwtvPlayWrapped = true;
    }

    function tick() {
        try {
            ensureStyle();
            attachSrc();
            allVideos().forEach(function (video) { revealIfDecoded(video); });
        } catch (e) { }
        setTimeout(tick, recovering ? 400 : 50);
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
                    attachSrc();
                    allVideos().forEach(function (video) { revealIfDecoded(video); });
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
