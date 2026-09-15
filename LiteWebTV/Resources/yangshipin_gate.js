(function () {
    'use strict';
    if (window.__lwtvYangshipinGate) return;
    window.__lwtvYangshipinGate = true;
    if (typeof window.__lwtvYangshipinArmed !== 'boolean') {
        window.__lwtvYangshipinArmed = false;
    }

    function hush(media) {
        if (!media) return;
        try {
            media.muted = true;
            media.volume = 0;
            if (typeof media.pause === 'function') media.pause();
        } catch (e) { }
    }

    function hushAll() {
        document.querySelectorAll('video,audio').forEach(hush);
    }

    var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
    if (proto && !proto.__lwtvYangshipinPlayWrapped) {
        var originalPlay = proto.play;
        proto.play = function () {
            if (window.__lwtvYangshipinArmed) {
                return originalPlay.apply(this, arguments);
            }
            hush(this);
            return Promise.resolve();
        };
        proto.__lwtvYangshipinPlayWrapped = true;
    }

    document.addEventListener('play', function (event) {
        if (window.__lwtvYangshipinArmed) return;
        hush(event.target);
    }, true);

    setInterval(function () {
        if (window.__lwtvYangshipinArmed) return;
        hushAll();
    }, 400);
})();
